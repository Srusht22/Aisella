// Gemini end to end on the LOCAL stack: the real handler, PostgREST with the seller's JWT, the real
// worker role and database rules, and the real GeminiProvider talking HTTP to a LOCAL stub of the
// Gemini API (no key, no network, no charge). It shows that switching the model provider keeps
// every server-side safeguard: grounding, tenant isolation, unapproved drafts, usage and cost.
//
//   AISELLIA_E2E=1 SUPABASE_TEST_URL=... SUPABASE_TEST_PUBLISHABLE_KEY=... SUPABASE_TEST_JWT_SECRET=... \
//   deno test --allow-net=127.0.0.1 --allow-env tests/gemini_e2e_local_test.ts
import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1.0.13";
import { GeminiProvider } from "../gemini_provider.ts";
import { createHandler } from "../handler.ts";
import { PostgrestSellerApi } from "../seller_api.ts";
import { PostgresWorkerDb } from "../worker_db.ts";
import {
  API,
  assertLocal,
  createConversation,
  createSeller,
  KEY,
  rpc,
  uuid,
  withWorker,
} from "./local_stack.ts";

const GEMINI_KEY = "test-not-a-real-gemini-key-0000000000";

Deno.test({
  name: "ai-assist with the Gemini provider end to end (local stub of the Gemini API)",
  ignore: Deno.env.get("AISELLIA_E2E") !== "1",
  sanitizeResources: false,
  sanitizeOps: false,
  async fn(t) {
    assertLocal();
    const seen: { url: string; key: string | null; body: string }[] = [];
    let answer: (store: Record<string, unknown>) => unknown = () => ({});
    const gemini = Deno.serve({ port: 0, hostname: "127.0.0.1", onListen: () => {} }, async (req) => {
      const body = await req.json();
      seen.push({ url: req.url, key: req.headers.get("x-goog-api-key"), body: JSON.stringify(body) });
      const storeBlock = body.systemInstruction.parts[1].text as string;
      const ctx = JSON.parse(storeBlock.replace(/^<store_context>/, "").replace(/<\/store_context>$/, ""));
      return Response.json({
        candidates: [{ content: { parts: [{ text: JSON.stringify(answer(ctx)) }] }, finishReason: "STOP" }],
        usageMetadata: { promptTokenCount: 4000, candidatesTokenCount: 200, thoughtsTokenCount: 300 },
        modelVersion: "gemini-2.5-pro",
        responseId: "resp-local",
      });
    });
    try {
      await withWorker(async (admin, workerUrl) => {
        const mk = (tag: string, product: string, price: number) =>
          createSeller(admin, {
            tag: `gem-${tag}`,
            storeName: `Gemini ${tag}`,
            zones: [{ name: "Erbil", fee: 5000, time_text: "1–2 days" }],
            products: [{
              name: product,
              base_price: price,
              variants: [{ option_values: [], initial_stock: 5 }],
            }],
          });
        const a = await mk("a", "Beige Abaya", 35000);
        await mk("b", "Secret Mug", 3000);
        const handler = createHandler({
          sellerApi: new PostgrestSellerApi(API, KEY),
          db: new PostgresWorkerDb(workerUrl),
          provider: new GeminiProvider({
            apiKey: GEMINI_KEY,
            baseURL: `http://127.0.0.1:${gemini.addr.port}`,
          }),
          settings: {
            model: "gemini-2.5-pro",
            effort: "low",
            maxTokens: 8000,
            providerTimeoutMs: 30000,
            budgetMs: 45000,
          },
          allowedOrigins: [],
          log: () => {},
        });
        const call = async (conv: string) => {
          const res = await handler(
            new Request("http://local/ai-assist", {
              method: "POST",
              headers: { Authorization: `Bearer ${a.token}` },
              body: JSON.stringify({
                store_id: a.store,
                conversation_id: conv,
                mode: "reply",
                idempotency_key: uuid(),
              }),
            }),
          );
          return (await res.json()).data;
        };
        const variant = (ctx: Record<string, unknown>) =>
          (ctx.catalog as { variants: { variant_id: string }[] }[])[0].variants[0].variant_id;
        const base = (over: Record<string, unknown>) => ({
          intent: "price_inquiry",
          reply_language: "en",
          reply: [],
          clarification: [],
          extraction: null,
          missing_fields: [],
          escalation: { required: false, reasons: [] },
          ...over,
        });

        await t.step("a grounded reply: the price is rendered by the server from the catalog", async () => {
          answer = (ctx) =>
            base({
              reply: [{ text: "It costs " }, { fact: "variant_price", ref: variant(ctx) }, { text: "." }],
            });
          const conv = await createConversation(a, [{ direction: "in", body: "How much is the abaya?" }]);
          const out = await call(conv);
          assertEquals(out.status, "succeeded");
          const c =
            (await rpc("get_conversation", { p_store_id: a.store, p_conversation_id: conv }, a.token)).data;
          assertEquals(c.suggestion.text, "It costs 35,000 IQD.");
          const [run] = await admin`select model, served_model, input_tokens, output_tokens, cost_micro_usd
                                      from app.ai_runs where id = ${out.run_id}`;
          assertEquals([run.model, run.served_model, run.input_tokens, run.output_tokens], [
            "gemini-2.5-pro",
            "gemini-2.5-pro",
            4000,
            500,
          ]);
          assert(Number(run.cost_micro_usd) > 0, "the run is costed, so the daily spending brakes apply");
        });

        await t.step("a model that invents a price is caught by the server, not trusted", async () => {
          answer = () => base({ reply: [{ text: "It costs 1,000 IQD, free delivery." }] });
          const conv = await createConversation(a, [{ direction: "in", body: "How much?" }]);
          const out = await call(conv);
          const c =
            (await rpc("get_conversation", { p_store_id: a.store, p_conversation_id: conv }, a.token)).data;
          assertFalse(String(c.suggestion?.text ?? "").includes("1,000"), `run ${out.status}`);
        });

        await t.step("the key travels only in the header; other stores' data never reaches Gemini", () => {
          assert(seen.length >= 2);
          for (const s of seen) {
            assertEquals(s.key, GEMINI_KEY);
            assertFalse(s.url.includes(GEMINI_KEY));
            assertFalse(s.body.includes("Secret Mug"));
          }
        });
      });
    } finally {
      await gemini.shutdown();
    }
  },
});
