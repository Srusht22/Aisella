# G. Test plan and minimum staging needs

## 1. Rules for Phase 9 testing

- **Fixtures and sandboxes only.** No live customer account is connected, no production webhook is configured, and no message reaches anyone outside the team's own test accounts.
- **No new provider charges.** Instagram dev mode, the WhatsApp test number and a Telegram test bot are free; template sends are not used.
- Local tests run against stubs: no network beyond `127.0.0.1`, as for `ai-assist`.

## 2. Local and CI tests (no provider involved)

| Layer | What | How |
|---|---|---|
| Adapter verification (Deno) | Valid signature; wrong secret; missing header; **re-serialized body fails**; non-ASCII Sorani payload; Telegram secret mismatch; oversized body | Fixtures signed with a test secret in the test |
| Adapter parsing (Deno) | Text, echo, delivery, read, attachment placeholder, unknown event types; multiple entries per Meta batch | Synthetic JSON shaped like the documented payloads; **no real customer data** |
| Adapter sending (Deno) | Success; 429 with `retry-after`; 5xx; permanent errors (window closed, blocked); timeout after send → `unknown` | Local HTTP stub of each provider's send API (as `anthropic_provider_test.ts`) |
| Ingestion (pgTAP) | Event deduplication; message deduplication; resolution by account id; unknown or disconnected account → ignored; stale events; out-of-order delivery receipts; batch lease expiry and retry; failure after 8 attempts | `api.channel_ingest` and `internal.channel_process_batch` with the ingest role |
| Isolation (pgTAP) | One account per store; a forged hint cannot attribute to another store; contacts, conversations and sends never cross stores; sandbox cannot hold a connection | Two stores, as suites 02 and 14 |
| Sending rules (pgTAP) | Permission; window; blocked contact; approved-order-only confirmations; rate limits; idempotency; the claim returns the authorized text; `unknown` not re-claimable; audit row per send | Seller JWT and sender role |
| Role guards (pgTAP 01) | `aisellia_channel_ingest` and `aisellia_channel_sender`: no attributes, no tables, exact function lists; **no AI role can execute a send function** | Extended guard suite |
| AI gating (pgTAP) | Auto-suggest off by default; debounce; per-contact cap; manipulation hit suppresses drafts | Existing AI fixtures |
| Retention (pgTAP) | Webhook payload purge at 14 days; anonymisation covers contacts | Job functions |
| End to end, local (Deno) | Signed fixture → webhook function → database → suggestion (scripted model) → seller send → sender → provider stub → echo fixture → `sent` | Like `e2e_local_test.ts` |
| App (Flutter) | Composer, "Use this reply", window countdown, send states, unknown resolution, order-related confirmation step, RTL, 200% text | Fake repository |
| Load (local) | 1,000 events burst: no duplicates, ordered display, lag under 1 min | Script against the local stack |

## 3. Staging integration test (later; needs approval)

**Goal:** prove the real platform path with **team-owned test accounts only**:
- the webhook handshake;
- signature verification with the real app secret;
- an inbound DM;
- an AI suggestion;
- a seller send;
- an echo or delivery receipt;
- a disconnect.

**Minimum infrastructure:**

| Item | Purpose | Cost |
|---|---|---|
| Supabase **staging project**, separate from production (AD-09: second Pro project, about USD 10 per month, to verify) | Migrations, Vault, `pg_cron`, Edge Functions, public HTTPS function URLs for webhooks | Small monthly fee; owner decision |
| Edge Functions: `channel-webhook`, `channel-send`, `channel-oauth`, `ai-assist` | Deployed **only after the owner authorizes staging deployment** | — |
| Meta developer account and **Meta app in development mode** (Instagram product) | Webhook subscription and Instagram Login | Free |
| A **team-owned Instagram professional account** with a role on the app (tester) | The "seller" side under Standard Access; no app review needed for app-role accounts | Free |
| A second team Instagram account | The "customer" sending DMs | Free |
| *(If WhatsApp is chosen)* the Meta **test WhatsApp number** and up to 5 verified team phones | Free test messaging; cannot reach real customers | Free |
| *(Optional)* a Telegram test bot | Harness for the generic pipeline | Free |
| Anthropic staging key with a Console spend limit (Phase 8.5) | AI suggestions in staging | Within the Phase 8.5 cap |

**Credentials the owner would provide, as Edge Function secrets or environment settings, never in the repository:**
- `SUPABASE_ACCESS_TOKEN` and the staging project ref, for deployment by an operator;
- the staging DB password, and generated passwords for `aisellia_ai_worker`, `aisellia_channel_ingest` and `aisellia_channel_sender`;
- `META_APP_ID`, `META_APP_SECRET`, `META_WEBHOOK_VERIFY_TOKEN` (a random value we generate);
- the OAuth redirect URL registered on the Meta app (the staging `channel-oauth` URL);
- *(WhatsApp)* the test WABA id, the test `phone_number_id`, and a system-user token for the test assets;
- *(Telegram)* the test bot token;
- `ANTHROPIC_API_KEY` (staging workspace).

**Exit criteria for the staging test:**
1. every pgTAP and Deno test passes on staging;
2. the preflight passes, extended for the channel roles;
3. the scripted round trip works with the two team accounts;
4. a forged webhook is rejected;
5. a duplicate webhook replay creates nothing;
6. logs contain no text or tokens;
7. a disconnect stops sends.

## 4. Before any real seller connects (not Phase 9 design scope)

- Meta app review and business verification for the chosen product.
- Phase 8.5 gates G1–G3 closed: evaluation, native review, the non-numeric fabrication decision.
- Privacy policy and seller terms covering channel data and AI processing.
- A support runbook for "needs attention" states.
