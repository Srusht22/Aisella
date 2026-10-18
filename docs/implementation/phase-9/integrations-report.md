# Phase 9: messaging integrations and Gemini (implementation report)

**Requested by the owner** on 2026-10-18, after provisionally accepting `2609682` (all five review fixes and their regression tests kept). Scope:
- all six integrations;
- Gemini as the primary AI provider;
- the open security risks fixed first.

**Status:** implemented and tested **locally**, and extended on the same day to the complete product experience (§7: app screens, background worker, account connection, WhatsApp templates, Arabic). **No provider is production-ready**: the official API pages could not be opened directly from this environment, so every provider capability is recorded as ASSUMPTION or UNRESOLVED, and the registry refuses to send until someone records it as VERIFIED. What could be confirmed from official search results is in [provider-verification.md](provider-verification.md).

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
  - `AI_MODEL`: default `gemini-2.5-pro` at first, changed to `gemini-3.8-flash` in `c99207d` (2.5 Pro is closed to new projects; §7), and it must match the provider;
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
| **WhatsApp** | `77e0c59` | `whatsapp_cloud`: text, captions, button replies, media as media ids, delivered/read/failed with error codes; phone kept for anonymisation | Cloud API `/{phone_number_id}/messages`, text, no link preview; ids validated before any request | Same; also needs a payment method. Templates outside 24 h added in `51d9a74` (§7) |
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

**Meta and TikTok connect** use OAuth or Embedded Signup. They were built later, in `70ace06` (§7); real use still needs Meta App Review and TikTok partner access.

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
3. **Not built yet:** media download (deferred on purpose: text first). The other items listed here at first (Meta and TikTok connect, WhatsApp templates, the app screens, a background sweep for queued sends) were built afterwards; see §7.
4. **Deployment and staging** need separate authorization ([K](../../architecture/phase-9/k-staging-setup-checklist.md), updated for the Vault-held provider secrets and Gemini).

**Phase 8.5 risks, unchanged and open:**
- the real-model evaluation (now with Gemini) has not run;
- native Sorani and Arabic review has not been done (including the new confirmation templates);
- no consented conversations have been collected;
- **non-numeric fabricated promises are not solved**.

Live AI suggestions stay disabled until these are addressed and tested.

## 7. Completing the product experience (same day, second request)

**Requested by the owner:** finish the missing features on the existing architecture, verify each provider against its official documentation, validate Gemini, and test everything. No deployment, no real account, no real message, no charge, no hosted migration.

### 7.1 Commits (all on `S.H_Branch`, pushed)

| Commit | Contents |
|---|---|
| `fafe063` | Provider verification record ([provider-verification.md](provider-verification.md)): verified facts kept apart from assumptions, per provider and for Gemini. Capability corrections (WhatsApp 1 message per 6 s to the same customer, text limits per provider, Viber subscribed users only, Messenger 1,999 characters); Graph API v26.0; WhatsApp 131049 marked as a permanent `marketing_limit` |
| `c99207d` | Gemini validation: default model `gemini-3.8-flash`; `thinkingLevel` for 3.x models; spending brakes count runs without a cost at a reserve, and a timeout is charged the reserve; 35-scenario evaluation set (en 20, ckb 8, ar 7) |
| `1d65606` | Background send worker (`channel-worker`) |
| `70ace06` | Five connection states; Meta (Instagram, Messenger), WhatsApp Embedded Signup and TikTok authorization (`channel-oauth`); TikTok token refresh |
| `51d9a74` | WhatsApp message templates outside the 24-hour window |
| `bdd090f` | App screens: connected accounts, live conversations, sending with confirmation, delivery status, templates, order confirmation |
| `af7b26c` | Arabic interface; wording for connected accounts |
| (this commit) | This report |

### 7.2 What was built

**Background worker** (`1d65606`, Edge Function `channel-worker`, sender role only):
- The database picks the due sends (`api.channel_due_sends`):
  - order kept per conversation;
  - the provider's minimum interval per customer (WhatsApp: 6 s);
  - at most 5 sends per account per cycle, so one busy account cannot starve the others;
  - suspended providers skipped.
- Each send goes through the same pipeline as before: claim, re-hash the exact text, adapter, report.
- **Retries:** at most 3 attempts, with backoff (5 s, 30 s, 2 min, or the provider's retry-after).
- **Unknown outcomes are never selected again.**
- A cycle never starts a send that could outlive its time budget.
- **Called by an external scheduler** with a bearer secret of at least 32 characters, compared in constant time. `pg_net` was not installed: installing it granted its functions to app roles (caught by suite 01).

**Connection flows** (`70ace06`):
- **Five states**, computed by the database: disconnected, awaiting authorization, connected, error, unavailable.
- **The nonce:** `begin_channel_connect` issues one per connection attempt (single use, 10 minutes, stored as a hash), and it doubles as the OAuth `state`.
- **Meta login (Instagram, Messenger):**
  - the code is exchanged server-side (POST with the app secret);
  - the granted Pages are listed, and only those with an Instagram account (for Instagram) are registered;
  - each Page is subscribed to the webhook.
- **WhatsApp Embedded Signup:**
  - a hosted page runs Meta's signup;
  - the number and business account ids are checked as numeric before use;
  - the business token goes to Vault.
- **TikTok:**
  - uses the documented `tt_user/oauth2` token exchange and refresh;
  - the authorize page URL must be configured, because it is not public;
  - the worker refreshes tokens that expire within two hours, and a refused refresh marks the account "error".
- **All or nothing:** the accounts granted in one attempt are registered together or not at all.
- **Tokens:** never logged, never returned to the app.

**WhatsApp templates** (`51d9a74`):
- **Sync:** the worker syncs each number's templates every 6 hours (`GET /{waba}/message_templates`, cursor followed only on the same host).
- **Which are usable:** only APPROVED UTILITY templates with a plain body and consecutive parameters. Marketing templates are never offered, and templates that disappear from Meta are marked MISSING.
- **The seller's send:**
  - the seller picks a template and fills its parameters: 1–300 characters, one line, no run of 4 spaces, no `{{`;
  - the **server renders the exact text**, which is authorized, hashed and audited like any message;
  - only the window check is skipped; blocked or anonymised customers, verified capability and rate limits still apply.
- **Before submitting:** the claim and the sender both re-render the template and refuse if it no longer hashes to the authorized text (`template_unavailable`, `text_integrity`).
- **Other providers:** they refuse template sends permanently.
- **"Send again":** an unknown template send carries its template and parameters when sent again.

**App screens** (`bdd090f`, `af7b26c`):
- **Connected accounts** (store menu): each account with its state and what it means; Telegram and Viber connect with a pasted bot token; Instagram, Messenger, WhatsApp and TikTok open the provider's page (https only) in the browser; disconnect asks first.
- **Bot tokens:**
  - sent once to `channel-connect`, cleared from the form when it closes, never stored by the app;
  - the test double records them only as `***`.
- **Live conversations:**
  - which account the conversation arrived on, and why replies cannot be sent when they cannot (account state, closed window, blocked customer);
  - a reply box;
  - "Use this reply" puts the AI suggestion in the box; it is never sent directly;
  - **every send opens a confirmation showing the exact text and the channel.**
- **Delivery per message:** waiting, sending, sent, delivered, read, not sent (with a reason from the safe error code), not known, cancelled; "will be tried again" while retrying.
- **Seller actions on a send:** cancel while queued. For an unknown outcome, "It arrived" or "Send again"; "Send again" first warns that the customer may receive it twice.
- **Closed window:** approved templates with a live preview of the exact text.
- **Approved order:** "Send order confirmation" sends the server-generated text (`kind = order_confirmation`), after the same confirmation.
- **Inbox:** shows the provider's name and flags a last reply that failed or whose outcome is unknown.
- **Arabic:**
  - all 877 strings (machine-drafted Modern Standard Arabic, pending native review like Sorani);
  - selectable at first launch and in Language and display;
  - Flutter's Arabic system strings; Iraqi month names; IQD written "د.ع".
- **Data exposed to the app:** two read-only additions to the conversation data ("channel" and each message's "send"), with no provider ids, phone numbers or credentials (pgTAP checks it).

### 7.3 Safety properties kept

- **No unsupervised AI reply:** `stores.ai_live_enabled` stays false, and no API can change it. An AI suggestion reaches a customer only through the seller's own confirmation of the exact text.
- **Who can send:** no AI role can authorize, send, claim, connect or send templates (suites 01, 22 and 24).
- **Exact text and audit:** exact-text validation, immutable authorization, audit hashes, duplicate protection and "unknown is never resent automatically" all hold for replies, confirmations and templates.
- **Gemini key:** server-side only (the `x-goog-api-key` header in the Edge Function). The app has no provider key.
- **Spending:** model failures and unknown costs cannot bypass the spending limits (`c99207d`, suite 16).
- **Earlier fixes:** the five security fixes and their regression tests from `2609682`, and the ingest fixes O1, O2 and O6, are unchanged.

### 7.4 Test results (fresh local database, 2026-10-18)

| Suite | Result |
|---|---|
| pgTAP, 24 suites | **1,122 assertions, all pass** (new: 23 send worker, 21; 24 templates and app data, 34; suites 01, 16, 21 and 22 extended) |
| AI-role HTTP checks | 17 / 17 |
| Deno `ai-assist`: fmt, lint, tests including the Gemini end to end | Clean; **72 pass** |
| Deno `_channels`: fmt, lint, tests including end to end (worker, OAuth, round trips) | Clean; **55 tests, 112 steps pass** |
| Edge Functions `channel-webhook`, `channel-send`, `channel-connect`, `channel-oauth`, `channel-worker` | fmt, lint and type check clean |
| Flutter: format, analyze, tokens, import boundaries, directional geometry | Clean |
| Flutter tests with the local backend | **323 / 323** (new: 20 channel and live-conversation tests, Arabic rendering, dates and amounts; 3 language-list goldens regenerated after review) |
| Login role passwords after the tests | All five `aisellia_*` roles have none |

**Failures found while building, all fixed before commit:**
- a Postgres regex repetition limit (`{1,512}`);
- a template "missing" rule that compared timestamps within one transaction;
- a spinner that kept the order-confirmation button busy while its dialog was open;
- cross-feature imports refused by the boundary check (shared labels moved to `features/common`);
- test-only mistakes (fixture ids, finders for the custom button).

### 7.5 Unresolved issues and blockers

1. **Official documentation not read directly.** Facts were confirmed from official search snippets, but capabilities stay `assumption`, so **no provider can send** until someone reads the pages and records each one as `verified` (URL and date).
2. **Real Gemini evaluation not run:** there is no API key in this environment. The plan-mode run of the 35 scenarios passes, and so do the adversarial end-to-end steps against the stub. Price rows for `gemini-3.8-flash` are assumptions.
3. **Provider gaps:**
   - TikTok's send body and webhook schema are unresolved: the adapter refuses unless `TIKTOK_SEND_PATH` is set, and the authorize URL must be configured;
   - Meta's Instagram subscription field names and delivery/read events are assumptions;
   - WhatsApp templates with headers, buttons or named parameters are not supported (they are synced but not offered).
4. **Platform approvals (owner):**
   - Meta App Review, Business Verification and Embedded Signup configuration;
   - a WhatsApp payment method;
   - TikTok partner access;
   - Viber commercial terms.
5. **Deferred on purpose:** media download, and Arabic as the store's reply-language setting (the stored setting is `ckb` or `en`; the assistant already answers in the customer's language).
6. **Language review:** native review of the Arabic and Sorani strings, including the confirmation templates, is still needed.
7. **Phase 8.5 risks still open:** non-numeric fabricated promises, and no consented real conversations. Live AI suggestions stay disabled.
8. **Deployment:** deployment, the worker's scheduler, hosted migrations and real accounts all need separate authorization ([K](../../architecture/phase-9/k-staging-setup-checklist.md)).
