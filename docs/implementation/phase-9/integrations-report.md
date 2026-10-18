# Phase 9: messaging integrations and Gemini (implementation report)

**Requested by the owner** on 2026-10-18, after provisionally accepting `2609682` (all five review fixes and their regression tests kept). Scope:
- all six integrations;
- Gemini as the primary AI provider;
- the open security risks fixed first.

**Status:** implemented and tested **locally**. **No provider is production-ready**: none of the official API pages could be read from this environment, so every provider capability is recorded as ASSUMPTION or UNRESOLVED, and the registry refuses to send until someone records it as VERIFIED.

**Boundaries kept:**
- no hosted database touched, nothing deployed;
- no real account connected, no real message sent, no charge incurred.

## 1. Commits (all on `S.H_Branch`, pushed)

| Commit | Contents |
|---|---|
| `354d0a8` | Gemini as the primary AI model provider |
| `a617aab` | Security prerequisites: webhooks verified and normalised in the database (O6), phone-number anonymisation (O2), echo matching (O1) |
| `e1d24b2` | Instagram adapter; Edge Functions `channel-webhook` and `channel-send`; send-dispatch ownership check |
| `1e92f84` | Facebook Messenger adapter |
| `77e0c59` | WhatsApp Business (Cloud API) adapter |
| `0081fe1` | Telegram Bot API adapter |
| `8b077ac` | Viber REST Bot API adapter |
| `342dc4e` | TikTok Business Messaging adapter, guarded (blocked) |
| `6a6f914` | Connect and disconnect for Telegram and Viber bots; Edge Function `channel-connect` |
| (this commit) | This report; staging checklist K and status updates |

## 2. Gemini (`354d0a8`)

- **Only the model-calling layer changed.** `ai-assist/gemini_provider.ts` implements the existing `AiProvider` seam: `models/{model}:generateContent` over REST.
- **Request handling:**
  - the key goes in the `x-goog-api-key` header, never in the URL;
  - output follows the JSON schema (`responseJsonSchema`; `GEMINI_STRUCTURED_OUTPUT=json_only` is a fallback);
  - thinking is set from the configured effort;
  - safety blocks map to `refusal`, and `MAX_TOKENS` to truncation;
  - one retry on 429 or 5xx, within the request's time budget;
  - error bodies are never copied.
- **Configuration:**
  - `AI_PROVIDER`: `gemini` by default; `anthropic` is kept;
  - `AI_MODEL`: default `gemini-2.5-pro`, and it must match the provider;
  - the inference region applies to Anthropic only;
  - a shared `provider_factory.ts` is used by the function and the eval runner;
  - the staging preflight checks the configured provider's key and model.
- **Unchanged:** the pipeline, database validation, reply guard, drafts that wait for the seller, tenant isolation and usage limits. The Gemini end-to-end test runs them through the real handler and database against a local Gemini stub.
- **Usage limits, made stricter:**
  - Gemini price rows were added (ASSUMPTION: the pricing page could not be read);
  - a model without a price is now costed at the highest known price. Before, its cost was null, so it escaped the daily spending brakes.
- **Live AI suggestions stay disabled.** `stores.ai_live_enabled` is false, and no API can change it.

## 3. Security prerequisites (`a617aab`), before any live flow

| Risk (MC-2 review) | Fix | Evidence |
|---|---|---|
| **O6** A leaked ingest credential could inject events for any account | The ingest role can no longer store normalised events. It can only hand over **raw bytes and the signature headers** (`api.channel_ingest_raw`). The database checks the signature with secrets only it can read (Vault): the provider app secret, a per-bot token or webhook secret, or a timestamped HMAC. It then normalises the body itself (`app.channel_normalize_<format>`). Per-bot webhooks are bound to the connection named in the URL. Refusals are counted, never stored. | Suite 20: forged, wrong-secret, changed-byte and re-serialised bodies are refused; bot A's secret cannot deliver into bot B; a replay older than 5 minutes is refused; the ingest role cannot call the storage step. Inbound kit for every provider. |
| **O2** `anonymize_customer` missed channel contacts identified by phone | Contacts keep the provider's phone identity (WhatsApp `wa_id`) in E.164 form. Anonymisation now also purges those contacts, their messages, AI outputs and webhook payloads, replaces the provider id, and blocks further messages (`CONTACT_ANONYMIZED`). | Suite 20; suite 21: a WhatsApp webhook → contact phone → anonymisation |
| **O1** An echo with the same text could resolve an unknown send | Text matching only for echoes the provider marks as sent by **our app** (Meta `app_id`) | Suites 18, 20 and 21 |

**Kept from earlier work:**
- server-generated order confirmations with exact-text validation;
- immutable send authorisation and audit hashes;
- duplicate protection;
- unknown outcomes never resent;
- live and pasted conversations kept apart (R1–R5).

**AI boundaries:** no AI role can approve, send, claim or connect (suites 01, 18 and 22).

## 4. Providers

All six use the same core:
- the database verifies and normalises webhooks;
- the seller authorises the exact text;
- the sender role re-hashes the text before submitting;
- the adapter maps results to sent, retriable, permanent or unknown.

**Common tests for each provider:**
- the outbound kit against a local imitation of its API: byte-identical en/ckb/ar text, the credential, safe error codes, timeout → unknown;
- the inbound kit through the database, with a full **round trip**: webhook → seller reply via PostgREST → sender role → exact bytes at the imitation;
- the normaliser's rules in pgTAP suite 21.

| Provider | Commit | Inbound (database) | Outbound | Status |
|---|---|---|---|---|
| **Instagram** | `e1d24b2` | `meta_sha256` with the app secret; messages, echoes (ours only by app id), attachments by kind only (no CDN URLs), reads with a mid | Graph `me/messages` with the Page token as Bearer | Implemented; **not verified, cannot send**; Meta App Review and OAuth connect pending |
| **Messenger** | `1e92f84` | Same normaliser with `object: page`; delivery receipts per mid; watermark-only reads ignored | `messaging_type: RESPONSE`, inside the 24-hour window | Same as Instagram |
| **WhatsApp** | `77e0c59` | `whatsapp_cloud`: text, captions, button replies, media as media ids, delivered/read/failed with error codes; phone kept for anonymisation | Cloud API `/{phone_number_id}/messages`, text, no link preview; ids validated before any request | Same; also needs a payment method. **Templates (outside 24 h) not implemented** |
| **Telegram** | `0081fe1` | Per-bot secret token; private chats only; ids `chat:message`; a shared contact's phone never stored | `sendMessage` as plain text; the token (in the URL path) never logged | Implemented, with connect and disconnect; **not verified, cannot send**. The token authenticates the sender, not the body (Telegram does not sign bodies). |
| **Viber** | `8b077ac` | Per-bot HMAC with the bot token; 64-bit message tokens kept exact | `send_message` with the store's name as sender; status codes in HTTP 200 mapped | Implemented, with connect and disconnect; **not verified, cannot send**; chatbot fees to confirm |
| **TikTok** | `342dc4e` | Timestamped `t.body` HMAC (assumption); assumed envelope in one function | Refuses unless `TIKTOK_SEND_PATH` is configured | **BLOCKED**: partner approval; formats UNRESOLVED (counted as absent) |

**Connect** (`6a6f914`), for Telegram and Viber:
1. The seller's nonce (`settings.manage`) is stored as a hash and expires in 10 minutes.
2. The provider confirms the token's bot.
3. A new connector login role (two functions, no tables) redeems the nonce.
4. The token and a fresh webhook secret go to Vault.
5. The webhook is registered.

Further rules:
- a bot connected to another store is refused;
- disconnecting deletes both secrets and cancels queued sends;
- account deletion removes them too;
- providers still in development cannot be connected by sellers.

**Meta and TikTok connect** use OAuth or Embedded Signup and need app review first, so they are **not built**.

**Sending endpoint** (`channel-send`): only a member of the send's store with `messages.send` can trigger it. This is checked with the caller's own JWT through `api.check_send_dispatch`.

## 5. Test results (fresh local database, 2026-10-18)

| Suite | Result |
|---|---|
| pgTAP, 22 suites | **1,062 assertions, all pass**. 941 before; new suites 20 (42), 21 (49) and 22 (27); suites 01, 13, 16, 17, 18 and 19 updated. |
| AI-role HTTP checks | 17 / 17 |
| Deno `ai-assist`: fmt, lint, type check, tests including end-to-end | Clean; **71 pass** (56 before; Gemini provider and Gemini end to end added) |
| Deno `_channels`: fmt, lint, type check, tests including end-to-end | Clean; **45 tests, 104 steps pass** |
| Deno `channel-webhook`, `channel-send`, `channel-connect` | fmt, lint and type check clean |
| Flutter: format, analyze, tokens, imports, directional | Clean |
| Flutter tests with the local backend | **300 / 300** |
| Role passwords after the tests | All five `aisellia_*` login roles have none |

**Failures found while building, fixed before each commit:**
- a Postgres regex repetition limit (`{32,256}`);
- test-only mistakes (event ids, leading-zero JSON numbers, temporary-table grants);
- one real property recorded rather than "fixed": Telegram cannot detect a changed body, so the kit's `signsBody: false` case.

**No safeguard was weakened.** Assertions that encoded "every provider is planned" were restated as "no real provider has a VERIFIED capability".

## 6. Blockers and what is still needed

1. **Official documentation not verified (all providers, and Gemini).** Network policy blocks the official sites. Before staging, someone must read the pages, then record each capability as `verified` with its URL and date. Until then:
   - no provider can send;
   - the request and response shapes, error codes and prices are assumptions.
2. **Platform approvals (owner):**
   - Meta App Review and Business Verification (Instagram, Messenger, WhatsApp; WhatsApp also needs a payment method);
   - TikTok partner access;
   - Viber commercial chatbot terms.
3. **Not built yet:**
   - OAuth or Embedded Signup connect for Meta and TikTok;
   - WhatsApp templates;
   - media download;
   - the Flutter screens (connections, composer with "Use this reply", send states, ckb/ar/en strings);
   - a background sweep for queued sends (today the app triggers `channel-send`).
4. **Deployment and staging** need separate authorization ([K](../../architecture/phase-9/k-staging-setup-checklist.md), updated for the Vault-held provider secrets and Gemini).

**Phase 8.5 risks, unchanged and open:**
- the real-model evaluation (now with Gemini) has not run;
- native Sorani and Arabic review has not been done (including the new confirmation templates);
- no consented conversations have been collected;
- **non-numeric fabricated promises are not solved**.

Live AI suggestions stay disabled until these are addressed and tested.
