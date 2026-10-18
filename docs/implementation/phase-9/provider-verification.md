# Phase 9: provider and Gemini verification record

**Checked:** 2026-10-18.

**Method:**
- Direct fetches of the official pages fail in this environment. DNS does not resolve `developers.facebook.com`, `core.telegram.org`, `developers.viber.com`, `business-api.tiktok.com` or `ai.google.dev`.
- I therefore used web searches **restricted to the official domains**. Each fact below is labelled:
  - **CONFIRMED (official search result):** quoted or paraphrased from a result served by the official domain;
  - **ASSUMPTION:** implemented from prior knowledge, not confirmed;
  - **CONTRADICTED → FIXED:** the implementation disagreed and was changed;
  - **NOT FOUND:** the search returned nothing usable.
- **None of this counts as a direct read.** In the database, the capabilities stay `assumption` (or `unresolved`), so no provider can send. Before staging, someone must open each page listed here and set the capability to `verified`, with its URL and date.

## Gemini

| Fact | Status | Source |
|---|---|---|
| `gemini-2.5-pro` has been limited, since 2026-09-18, to projects that used it before; new projects get 404 / "no longer available to new users". **The configured default was unusable for a new Aisellia project.** | CONTRADICTED → FIXED: default is now `gemini-3.8-flash` | ai.google.dev/gemini-api/docs/changelog; ai.google.dev/gemini-api/docs/models/gemini-2.5-pro |
| `gemini-3.8-flash` is listed as **Stable** on its model page. On 2026-10-08, requests to `gemini-3.7-flash` are routed to it. | CONFIRMED | ai.google.dev/gemini-api/docs/models/gemini-3.8-flash; changelog |
| `gemini-3.5-flash` → `gemini-3.6-flash`, and `gemini-4-argon` is GA (2026-10-13) | CONFIRMED | changelog |
| `gemini-3.8-flash` price: $0.75 / $3.75 per 1M input / output tokens until 2026-12-31; **$1.50 / $7.50 from 2027-01-01** | CONFIRMED. The price table uses the higher 2027 price, so the spending caps act early, never late. | ai.google.dev/gemini-api/docs/pricing |
| REST auth with the `x-goog-api-key` header; `thinkingConfig` under `generationConfig` | CONFIRMED | ai.google.dev/gemini-api/docs/… (thinking guide) |
| `thinking_level` (minimal/low/medium/high) recommended over `thinking_budget` for 3.x and later; `gemini-4-argon` rejects `minimal` | CONFIRMED → the adapter now sends `thinkingLevel` low/medium/high for 3.x+ (never `minimal`) | ai.google.dev (Gemini 3.5 and 4 guides) |
| `responseJsonSchema` accepts a JSON Schema subset and silently drops unknown keywords. One reference page labels it "(deprecated)" next to a newer Interactions API `response_format`. | PARTLY CONFIRMED / UNCLEAR. The server validates every output anyway; `GEMINI_STRUCTURED_OUTPUT=json_only` is the fallback. | ai.google.dev structured-output pages; forum |
| Whether the model ID works for **this** key | NOT VERIFIABLE without a key. `ops/staging_check.ts --check-provider` does a free `models.get`. | — |

## Meta: Instagram, Messenger, WhatsApp

| Fact | Status | Source |
|---|---|---|
| Webhooks: `X-Hub-Signature-256: sha256=<HMAC-SHA256(raw payload, app secret)>`; GET handshake checks `hub.verify_token` and returns `hub.challenge` | CONFIRMED (matches `meta_sha256` and `api.channel_webhook_challenge`) | developers.facebook.com/documentation/business-messaging/messenger-platform/webhooks |
| Webhook calls time out after 20 s and are retried until a 200 | CONFIRMED (ingest only stores, then answers) | same |
| Instagram over Facebook Login uses the Messenger Platform's `/<PAGE_ID>/messages` with the Page token and the IGSID as recipient | CONFIRMED (adapter: `me/messages` with the Page token) | …/instagram-messaging/get-started |
| Echoes come with the `messages` field for Instagram; `app_id` is the sending app (the Page inbox's app id when sent from the inbox, since v12) | CONFIRMED (O1 matching uses our app id) | …/message-echoes |
| Messenger text must be **under 2000** characters | CONFIRMED → capability set to 1999 | …/messenger-platform/reference/send-api |
| Instagram text limit of 1000 | NOT FOUND (kept at 1000, the conservative value) | — |
| 24-hour standard window; Human Agent tag up to 7 days, only after App Review | CONFIRMED (tag deferred to 9b) | …/messenger-platform/policy; human-agent-escalation |
| WhatsApp text: `messaging_product`, `recipient_type`, `to`, `type: text`, `text.preview_url`, `text.body` (max 4096); response `messages[0].id` (wamid) | CONFIRMED | …/whatsapp/reference/…/message-api |
| WhatsApp free-form text only inside the 24-hour customer-service window; **templates** outside it | CONFIRMED → templates implemented | same; …/whatsapp/templates/overview |
| Template send: `type: template`, `template.name`, `template.language.code`, `components[{type: body, parameters[{type: text, text}]}]`; named parameters add `parameter_name` | CONFIRMED (positional parameters implemented) | …/templates/overview |
| Errors: 131047 = more than 24 h since the last reply (send a template); 131026 undeliverable; 130429 throughput; 131056 pair rate limit (**1 message per 6 s to the same user**); 131049 marketing limit (wait 24 h) | CONFIRMED → 131049 added as permanent `marketing_limit`; pair interval added to the capabilities | …/whatsapp/support/error-codes; …/throughput |
| Throughput 80 messages per second per number by default | CONFIRMED (recorded) | …/whatsapp/throughput |
| Graph API version: official examples use v23.0–v26.0 | CONTRADICTED (the default was v21.0) → FIXED: default v26.0, configurable | several pages |
| Facebook Login code exchange: GET `oauth/access_token` with `client_id`, `redirect_uri` (same as the login), `client_secret`, `code`, **server to server only** | CONFIRMED → `channel-oauth` | …/facebook-login/guides/advanced/manual-flow |
| Page tokens through `{user-id}/accounts`; subscribe the app with POST `/{page-id}/subscribed_apps?subscribed_fields=messages` (Page token; `pages_messaging`, `pages_manage_metadata`) | CONFIRMED | …/facebook-login/guides/access-tokens/get-long-lived; Pages API / Messenger webhooks |
| Embedded Signup returns `waba_id`, `phone_number_id` and a code that lives **30 s**; exchange server to server; register the number; subscribe the app on the WABA (`/{waba_id}/subscribed_apps`); `/{waba_id}/phone_numbers` lists the numbers. "Beta, subject to change." | CONFIRMED → WhatsApp connect | …/whatsapp/embedded-signup/overview, implementation |
| Phone-number registration request body (PIN) | NOT FOUND → registration is left to the owner in Meta's tools; Aisellia does not register numbers | — |

## Telegram

| Fact | Status | Source |
|---|---|---|
| `sendMessage` text 1–4096 characters after entity parsing; flood errors carry `parameters.retry_after` | CONFIRMED | core.telegram.org/bots/api |
| `secret_token` 1–256 characters `[A-Za-z0-9_-]`, sent back in `X-Telegram-Bot-Api-Secret-Token` | Third-party docs only (aiogram); the official page was not returned → ASSUMPTION | — |
| `getMe`, `setWebhook` `allowed_updates` | NOT FOUND in the official results → ASSUMPTION | — |

## Viber

| Fact | Status | Source |
|---|---|---|
| `X-Viber-Auth-Token` on every request; callbacks signed HMAC-SHA256 with the auth token, in `X-Viber-Content-Signature` | CONFIRMED | developers.viber.com/docs/api/rest-bot-api/ |
| `sender.name` required, max 28 characters; the response has `message_token` | CONFIRMED | same |
| A bot can message only **subscribed** users | CONFIRMED (recorded) | same |
| The full numeric `status` code table | NOT FOUND → the mapping stays an assumption | — |

## TikTok

| Fact | Status | Source |
|---|---|---|
| The Business Messaging API exists: open beta in APAC, LATAM, **METAP** and North America (not EEA, CH, UK); reviews required; only accounts with Advanced Access or Verified Business Accounts | CONFIRMED | business-api.tiktok.com/portal/docs/access-to-business-messaging-api/v1.3 |
| Send endpoint `/open_api/v1.3/business/message/send/` ("send a message to a conversation") | CONFIRMED (path); **the body fields were NOT FOUND** → TikTok still refuses to send | …/business-messaging/v1.3 |
| Webhooks: event type `DIRECT_MESSAGE`; generic TikTok webhooks sign `timestamp + "." + body` with HMAC-SHA256 in `TikTok-Signature`, key = client secret | CONFIRMED for generic webhooks (matches `tiktok_sha256`); that Business Messaging uses the same key is unconfirmed | developers.tiktok.com/docs/en/webhooks-verification |
| The DIRECT_MESSAGE payload schema | NOT FOUND → the normaliser stays UNRESOLVED | — |
| Account authorization: POST `/open_api/v1.3/tt_user/oauth2/token/` with `client_id`, `client_secret`, `grant_type=authorization_code`, `auth_code`, `redirect_uri`; returns `access_token` (1 day), `refresh_token` (1 year), `open_id`, `expires_in`; refresh at `/tt_user/oauth2/refresh_token/`; the auth code lives 10 min and works once | CONFIRMED → TikTok connect and token refresh implemented | …/accounts-api-authentication/v1.3 |

## Conclusion

**No provider is production-ready.** The facts confirmed above reduce the risk, but none of them is a direct read. These remain open for each provider:

| Provider | Still open |
|---|---|
| Meta | App Review, Business Verification, Embedded Signup "beta" |
| Telegram | setWebhook and secret-token rules unconfirmed |
| Viber | Status table; commercial terms |
| TikTok | Payload and send body unknown; reviews |
| Gemini | Not run with a real key |
