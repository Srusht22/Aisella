// Helpers for tests and evaluations that run against the LOCAL Supabase stack only.
import postgres from "postgres";

export const API = Deno.env.get("SUPABASE_TEST_URL") ?? "";
export const KEY = Deno.env.get("SUPABASE_TEST_PUBLISHABLE_KEY") ?? "";
const SECRET = Deno.env.get("SUPABASE_TEST_JWT_SECRET") ?? "";
export const ADMIN_DB = Deno.env.get("SUPABASE_DB_URL") ??
  "postgresql://postgres:postgres@127.0.0.1:54322/postgres";

export function assertLocal(): void {
  for (const u of [API, ADMIN_DB]) {
    if (!["127.0.0.1", "localhost"].includes(new URL(u).hostname)) {
      throw new Error("refusing to run against a non-local stack");
    }
  }
  if (!KEY || !SECRET) throw new Error("set SUPABASE_TEST_PUBLISHABLE_KEY and SUPABASE_TEST_JWT_SECRET");
}

export const uuid = () => crypto.randomUUID();

export const b64 = (data: Uint8Array | string) =>
  btoa(typeof data === "string" ? data : String.fromCharCode(...data)).replace(/=+$/, "").replace(/\+/g, "-")
    .replace(/\//g, "_");

/** A seller JWT signed with the LOCAL stack's secret (what GoTrue would issue after sign-in). */
export async function sellerJwt(userId: string): Promise<string> {
  const head = b64(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const body = b64(JSON.stringify({
    sub: userId,
    role: "authenticated",
    aud: "authenticated",
    exp: Math.floor(Date.now() / 1000) + 600,
  }));
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${head}.${body}`)),
  );
  return `${head}.${body}.${b64(sig)}`;
}

export async function rpc(fn: string, params: Record<string, unknown>, token: string) {
  const res = await fetch(`${API}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: {
      apikey: KEY,
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      "Content-Profile": "api",
      "Accept-Profile": "api",
    },
    body: JSON.stringify(params),
  });
  return await res.json();
}

/** Gives the local worker role a random password for the duration of `fn`, then removes it. */
export async function withWorker<T>(fn: (admin: postgres.Sql, workerUrl: string) => Promise<T>): Promise<T> {
  const admin = postgres(ADMIN_DB, { max: 1, onnotice: () => {} });
  const password = b64(crypto.getRandomValues(new Uint8Array(24)));
  await admin.unsafe(`alter role aisellia_ai_worker password '${password}'`);
  try {
    return await fn(
      admin,
      `postgresql://aisellia_ai_worker:${encodeURIComponent(password)}@127.0.0.1:54322/postgres`,
    );
  } finally {
    await admin.unsafe("alter role aisellia_ai_worker password null");
    await admin.end();
  }
}

export interface ProductSpec {
  name: string;
  base_price: number;
  description?: string;
  category?: string;
  option_types?: string[];
  variants: { option_values: string[]; initial_stock: number; price_override?: number }[];
}

export interface Seller {
  user: string;
  token: string;
  store: string;
  zones: Record<string, string>;
  variants: Record<string, string>;
}

/** A confirmed seller with a store, zones, products and policies, created through the real API. */
export async function createSeller(
  admin: postgres.Sql,
  spec: {
    tag: string;
    storeName: string;
    replyLocale?: "ckb" | "en";
    zones: { name: string; fee: number; time_text: string | null }[];
    products: ProductSpec[];
    policies?: { topic: string; body: string }[];
  },
): Promise<Seller> {
  const user = uuid();
  await admin`insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, raw_user_meta_data)
              values (${user}, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
                      ${`${spec.tag}-${
    user.slice(0, 8)
  }@example.test`}, now(), '{"terms_version": "2026-10"}')`;
  const token = await sellerJwt(user);
  const store = (await rpc("create_store", {
    p_name: spec.storeName,
    p_contact_phone: "+9647501234567",
    p_currency: "IQD",
    p_reply_locale: spec.replyLocale ?? "en",
    p_business_city: "Erbil",
    p_idempotency_key: uuid(),
  }, token)).data.id as string;
  const zones: Record<string, string> = {};
  for (const z of spec.zones) {
    zones[z.name] = (await rpc("upsert_zone", {
      p_store_id: store,
      p_zone_id: null,
      p_expected_version: null,
      p_name: z.name,
      p_fee: z.fee,
      p_time_text: z.time_text,
      p_idempotency_key: uuid(),
    }, token)).data.id;
  }
  const variants: Record<string, string> = {};
  for (const p of spec.products) {
    const res = await rpc("upsert_product", {
      p_store_id: store,
      p_product_id: uuid(),
      p_expected_version: null,
      p_idempotency_key: uuid(),
      p_product: {
        name: p.name,
        base_price: p.base_price,
        description: p.description ?? null,
        category: p.category ?? null,
        track_stock: true,
        status: "active",
        option_types: p.option_types ?? [],
        images: [],
        variants: p.variants,
      },
    }, token);
    for (const v of res.data.variants as { id: string; label: string }[]) {
      variants[v.label ? `${p.name} / ${v.label}` : p.name] = v.id;
    }
  }
  for (const pol of spec.policies ?? []) {
    await rpc("upsert_policy", {
      p_store_id: store,
      p_policy_id: null,
      p_expected_version: null,
      p_topic: pol.topic,
      p_body: pol.body,
      p_active: true,
      p_idempotency_key: uuid(),
    }, token);
  }
  return { user, token, store, zones, variants };
}

export async function createConversation(
  seller: Seller,
  messages: { direction: "in" | "out"; body: string }[],
  source = "instagram",
): Promise<string> {
  return (await rpc("create_conversation", {
    p_store_id: seller.store,
    p_source: source,
    p_customer_label: null,
    p_messages: messages,
    p_idempotency_key: uuid(),
  }, seller.token)).data.id as string;
}
