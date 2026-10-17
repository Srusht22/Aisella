# M. Platform comparison matrix (multi-channel, public launch)

**Checked:** 2026-10-17.

**Labels:**
- **VERIFIED:** stated on an official provider page (developers.facebook.com, business.whatsapp.com, whatsapp.com, core.telegram.org, telegram.org, help.viber.com, developers.viber.com, creators.viber.com, forbusiness.viber.com, business-api.tiktok.com).
- **ASSUMPTION:** our reasoned expectation, not stated officially.
- **UNRESOLVED:** not found, or the sources conflict.

**Method limit:**
- Direct access to these official sites is **blocked by this environment's network policy**. Official pages were read through a web search restricted to those domains, which returns extracts of the pages.
- **VERIFIED therefore means "official page, as extracted by the search index", not a direct read.** Every VERIFIED row must be read directly, and dated, before the provider's implementation milestone.
- Regional news is labelled as such, never as VERIFIED.

**No platform is selected.** This page informs the seller interviews ([J](j-seller-interview-questionnaire.md)) and the owner's decision.

## 1. Summary

| | Instagram | WhatsApp | Messenger | Telegram | Viber | TikTok |
|---|---|---|---|---|---|---|
| Customer writes to | The seller's professional account (V) | The seller's business number (V) | The seller's Facebook Page (V) | A **bot** (V); or a seller's business account via a connected bot (V) | A **bot** (V) | The seller's business account (V) |
| Third-party multi-seller platform model | Yes, with Advanced Access and App Review plus Business Verification (V) | Yes, as **Tech Provider** (V) | Yes, `pages_messaging` with App Review (V) | Bots per seller (V); the terms for hosting many sellers' bots are not checked (U) | Commercial contract **per bot** (V) | Yes, after TikTok developer reviews (V) |
| Messaging cost | No official statement found (U) | Replies charged beyond 1,000 per number per month since 2026-10-01 (V); Iraq amounts (U) | No official statement found (U) | Free; paid broadcasts are optional (V) | **EUR 115 per bot per month** (V; an older FAQ says EUR 100); in-session free; bot-initiated messages charged (V) | No official statement found (U) |
| Reply window | 24 h (V) | 24 h; templates outside it (V) | 24 h; tags outside it (V) | None documented for replies (U) | 24 h session (V) | (U) |
| Delivery / read status | Echoes in `messages`; `messaging_seen` (V) | Sent, delivered, read, failed webhooks (V) | Delivery and read webhooks (A) | No delivery receipts in the Bot API (A) | (U) | (U) |
| Iraq / Kurdistan Region | Business Verification eligibility for Iraq (U) | Iraq not among ineligible countries (V); coexistence for Iraqi numbers not listed (U) | As Instagram (U) | Suspended in federal Iraq from 2026-05-03 (not the Kurdistan Region), then restored (news, U) | Iraq rate on the rate card (U) | API in open beta in "METAP" (V); whether Iraq is included (U) |
| Implementation complexity | Medium (A) | High (A) | Medium; shares Meta plumbing with Instagram (A) | Low (A) | Medium, plus a contract (A) | Medium–high (A) |
| Ongoing operations | Medium: token refresh every 60 days, review compliance (A) | High: billing, number management, quality ratings (A) | Medium (A) | Low (A) | Medium: fees per bot per seller (A) | Medium–high: reviews, beta changes (A) |

V = VERIFIED, A = ASSUMPTION, U = UNRESOLVED.

## 2. Instagram (Instagram API with Instagram Login)

| Dimension | Claim | Label | Source |
|---|---|---|---|
| Account eligibility | Instagram **professional** account (business or creator) | VERIFIED | [Instagram Platform overview](https://developers.facebook.com/docs/instagram-platform/overview/) |
| Access for accounts we do not own | **Advanced Access**, which needs **App Review and Business Verification**; Standard Access only covers accounts with roles on the app | VERIFIED | Same |
| Permissions | `instagram_business_basic`, `instagram_business_manage_messages`; allowed use includes third-party CRM tools; review needs a screencast | VERIFIED | [Instagram Login](https://developers.facebook.com/docs/instagram-platform/instagram-api-with-instagram-login/); permissions reference |
| Window | 24 h; Human Agent tag up to 7 days (deferred to Phase 9b) | VERIFIED | [Messaging API](https://developers.facebook.com/documentation/instagram-platform/instagram-api-with-instagram-login/messaging-api) |
| Media | Sends audio (aac, m4a, wav, mp4) and video (mp4, ogg, avi, mov, webm) up to 25 MB; inbound attachments include audio, video, image, file, reel | VERIFIED | Same; [Messenger webhooks](https://developers.facebook.com/documentation/business-messaging/messenger-platform/webhooks) |
| Voice notes | Arrive as `audio` attachments | ASSUMPTION | — |
| Rate limits | 300 calls/s per account for text; 10 calls/s for audio and video | VERIFIED | [Rate limiting](https://developers.facebook.com/documentation/business-messaging/messenger-platform/overview/rate-limiting) |
| Webhook security and reliability | `X-Hub-Signature-256` over the escaped payload; 20 s timeout; the app is unsubscribed after persistent failures | VERIFIED | Messenger webhooks; [FAQ](https://developers.facebook.com/documentation/business-messaging/messenger-platform/faq) |
| Tokens | 60-day tokens, refreshable after 24 h; an unrefreshed token expires | VERIFIED | [Refresh token](https://developers.facebook.com/docs/instagram-platform/reference/refresh_access_token/) |
| Cost | No per-message pricing statement found | UNRESOLVED | — |
| Max text length | Not found | UNRESOLVED | — |
| Iraq Business Verification | No official eligibility list found | UNRESOLVED | [Business verification](https://www.facebook.com/business/help/2058515294227817) |
| Data deletion | A data-deletion URL or callback is required to publish | VERIFIED | [Publish checklist](https://developers.facebook.com/documentation/pages-api/create-an-app) |

## 3. WhatsApp Business Platform (Cloud API)

| Dimension | Claim | Label | Source |
|---|---|---|---|
| Eligibility | Businesses in Cuba, Iran, North Korea, Syria and three Ukrainian regions are ineligible; Iraq is not listed | VERIFIED | [WhatsApp support](https://developers.facebook.com/documentation/business-messaging/whatsapp/support) |
| Multi-seller model | **Tech Provider**: Business Verification, App Review, advanced `whatsapp_business_management`; Embedded Signup | VERIFIED | [Tech Provider](https://developers.facebook.com/documentation/business-messaging/whatsapp/solution-providers/get-started-for-tech-providers) |
| Embedded Signup | v2 and v3 deprecated 2026-10-15; v4 | VERIFIED (partly) | [Implementation](https://developers.facebook.com/documentation/business-messaging/whatsapp/embedded-signup/implementation/) |
| Separate number vs coexistence | Coexistence needs app ≥ 2.24.17 and Tech Provider status; caps a shared number at 20 messages/s; disables some app features | VERIFIED | [Onboard Business app users](https://developers.facebook.com/documentation/business-messaging/whatsapp/embedded-signup/onboarding-business-app-users/) |
| Coexistence for Iraqi numbers | Not in the listed countries | UNRESOLVED (likely unavailable) | [Changelog](https://developers.facebook.com/documentation/business-messaging/whatsapp/changelog) |
| Cost | Service replies charged since **2026-10-01** beyond **1,000 per number per month**; no delivery after the free tier without a payment method; utility in-window charged | VERIFIED | [Pricing](https://developers.facebook.com/documentation/business-messaging/whatsapp/pricing); [non-template updates](https://developers.facebook.com/documentation/business-messaging/whatsapp/pricing/non-template-messages) |
| Iraq rate | Iraq is a named market; the amounts were not retrieved | UNRESOLVED | Pricing page and rate card |
| Window and templates | 24 h, reset by each customer message; templates outside it | VERIFIED | Pricing; [service messages](https://developers.facebook.com/documentation/business-messaging/whatsapp/messages/send-messages) |
| Media and voice | Inbound types include text, image, audio, **voice**, video, document, location, contacts; voice sent as OGG/Opus; audio up to 16 MB | VERIFIED | [Audio messages](https://developers.facebook.com/documentation/business-messaging/whatsapp/messages/audio-messages); message API reference |
| Throughput | 1 message per 6 s per recipient; a new portfolio starts at 250 unique recipients per 24 h and 2 numbers | VERIFIED | [Throughput](https://developers.facebook.com/documentation/business-messaging/whatsapp/throughput); [messaging limits](https://developers.facebook.com/documentation/business-messaging/whatsapp/messaging-limits) |
| Webhooks | Retries up to 7 days; duplicates possible; delivered and failed for the same message possible | VERIFIED | [Webhooks](https://developers.facebook.com/documentation/business-messaging/whatsapp/webhooks/overview/) |
| Policy on AI | AI-provider clause; escalation to humans required; no training on data | VERIFIED; **legal classification UNRESOLVED** | [Business Solution Terms](https://www.whatsapp.com/legal/business-solution-terms); [Business Policy](https://business.whatsapp.com/policy) |
| Sandbox | Test number and account, no payment method; some webhooks not sent in dev mode | VERIFIED | [About the platform](https://developers.facebook.com/documentation/business-messaging/whatsapp/about-the-platform); support |

## 4. Facebook Messenger (Messenger Platform)

| Dimension | Claim | Label | Source |
|---|---|---|---|
| Account | A Facebook Page | VERIFIED | [Get started](https://developers.facebook.com/documentation/business-messaging/messenger-platform/get-started) |
| Permission and review | `pages_messaging`; the Human Agent permission is requested through App Review | VERIFIED | [Send API](https://developers.facebook.com/docs/messenger-platform/reference/send-api/) |
| Business Verification for Advanced Access | Expected, as for Instagram | ASSUMPTION | — |
| Window and tags | 24 h standard window; tags only for approved non-promotional cases; **from 2026-04-27 three tags (CONFIRMED_EVENT_UPDATE, ACCOUNT_UPDATE, POST_PURCHASE_UPDATE) return error 100** | VERIFIED | [Send messages](https://developers.facebook.com/documentation/business-messaging/messenger-platform/send-messages); Send API |
| Media | Audio, file, image, template, video; 25 MB | VERIFIED | Send API |
| Webhooks | Same Meta signature, 20 s timeout, unsubscribe on persistent failure | VERIFIED | Messenger webhooks; FAQ |
| Cost | No per-message pricing statement found | UNRESOLVED | — |
| Kurdistan relevance | Facebook is used by 68% in the Kurdistan Area (Ipsos survey, 2025) | ASSUMPTION (third-party survey) | intaj.net |

## 5. Telegram (Bot API)

| Dimension | Claim | Label | Source |
|---|---|---|---|
| Account model | Customers message a **bot**. With Telegram Business, a bot can be connected to a business account and reply via `business_connection_id`, if `can_reply` is granted, for chats with incoming messages in the last 24 h | VERIFIED | [Bot API](https://core.telegram.org/bots/api); [connected business bots](https://core.telegram.org/api/bots/connected-business-bots) |
| Telegram Business price or Premium requirement | Not found officially | UNRESOLVED | — |
| Webhook security | `secret_token` → `X-Telegram-Bot-Api-Secret-Token` | VERIFIED | Bot API |
| Limits | About 30 messages/s overall, about 1 per second per chat, 20 per minute in groups; paid broadcasts up to 1,000/s for Stars (the thresholds differ between pages) | VERIFIED (thresholds UNRESOLVED) | [Bots FAQ](https://core.telegram.org/bots/faq) |
| Cost | Free for normal messaging | VERIFIED | Bots FAQ |
| Delivery and read receipts | Not offered to bots | ASSUMPTION | — |
| Webhook retry policy | Not found in this check | UNRESOLVED | — |
| Multi-seller terms | The Bot Platform Developer Terms exist; not reviewed for hosting many sellers' bots | UNRESOLVED | [Developer terms](https://telegram.org/tos/bot-developers) |
| Iraq | **Suspended in federal Iraq from 2026-05-03, excluding the Kurdistan Region, then restored after Telegram agreed to regulatory conditions**; an earlier suspension in 2023 was reversed within about a week | UNRESOLVED (news, not official provider or government source) | [Rudaw](https://www.rudaw.net/english/middleeast/iraq/090520261); [964media](https://en.964media.com/47442/); [Kurdistan24](https://www.kurdistan24.net/en/story/392254/Iraq-reverses-Telegram-ban-after-a-week) |

## 6. Viber (Bot API, Rakuten Viber)

| Dimension | Claim | Label | Source |
|---|---|---|---|
| Creating bots | Since **2024-02-05**, new bots only on **commercial terms**, through verified partners or Viber directly, with manual review and a contract | VERIFIED | [Bot commercial model](https://help.viber.com/hc/en-us/articles/15247629658525-Bot-commercial-model); [FAQ](https://help.viber.com/hc/en-us/articles/15383950711197-Rakuten-Viber-chatbot-commercial-model-FAQ) |
| Cost | **EUR 115 per bot per month** (an older FAQ says EUR 100); session messages free; chatbot-initiated messages charged per delivered message by country; welcome messages free | VERIFIED (amount partly conflicting) | Same; [rate card PDF](https://www.forbusiness.viber.com/documents/chatbots.pdf) |
| Implication for multi-seller SaaS | If each seller needs their own bot, **each seller costs at least EUR 115 per month** before any message | ASSUMPTION (derived) | — |
| Session | 24 h from the subscriber's message | VERIFIED | Bot commercial model |
| Who can be messaged | Only users subscribed to the bot | VERIFIED | [Send message](https://creators.viber.com/docs/bots-api/resources/messaging/send-message) |
| Webhook security | `X-Viber-Content-Signature`: HMAC-SHA256 with the bot token; a valid CA certificate is required | VERIFIED | [Webhooks](https://creators.viber.com/docs/bots-api/getting-started/web-hooks); [REST API](https://developers.viber.com/docs/api/rest-bot-api/) |
| Billing visibility | `billing_status` 0–5 on each send | VERIFIED | Send message |
| Operational requirement | Respond in under 5 s; handle all message types | VERIFIED (older page) | Developer docs |
| Iraq rate; Kurdistan usage | Rate not retrieved; Viber has a Sorani interface and a regional user base | UNRESOLVED / ASSUMPTION | [Kurdistan24](https://www.kurdistan24.net/en/story/23889-Viber,-one-of-world%E2%80%99s-leading-messaging-apps,-adds-Kurdish-language) |

## 7. TikTok (Business Messaging API)

| Dimension | Claim | Label | Source |
|---|---|---|---|
| Account eligibility | Only **Advanced Access or Verified Business Accounts**; personal accounts excluded | VERIFIED | [Access to Business Messaging API](https://business-api.tiktok.com/portal/docs/access-to-business-messaging-api/v1.3) |
| Developer access | Pass TikTok's **data security and privacy review**; US accounts also need the US data security review and the USDS addendum | VERIFIED | Same; [US review](https://business-api.tiktok.com/portal/docs/us-data-security-review/v1.3) |
| Regions | Not available for accounts registered in the EEA, Switzerland or the UK; **open beta in APAC, LATAM, METAP and North America** | VERIFIED | Access page; [Education hub](https://business-api.tiktok.com/portal/bm-api/education-hub) |
| Iraq in METAP | Not confirmed | UNRESOLVED | — |
| Capabilities | Send to a conversation, list conversations and messages, upload images, download images and videos; text, images and TikTok posts; DIRECT_MESSAGE webhooks; comment-to-message | VERIFIED | [Overview](https://business-api.tiktok.com/portal/docs/business-messaging-api-overview/v1.3); [API reference](https://business-api.tiktok.com/portal/docs/business-messaging/v1.3); [webhook config](https://business-api.tiktok.com/portal/docs/get-a-business-messaging-webhook-configuration/v1.3) |
| Reply window and messaging limits | Pages exist but their content was not retrieved | UNRESOLVED | Messaging limits page |
| API rate levels | Basic 10 QPS / 600 QPM / 864,000 QPD; Advanced 20 / 1,200 / 1,728,000 (general API) | VERIFIED | [Rate limits](https://business-api.tiktok.com/portal/docs/rate-limits/v1.3) |
| Webhook signature method | Not retrieved | UNRESOLVED | — |
| Cost | Not found | UNRESOLVED | — |
| Kurdistan note | TikTok briefly restricted searches for "Kurdistan" in September 2026, then restored them | UNRESOLVED (news) | [PUKmedia](https://pukmedia.com/EN/Details/82782) |

## 8. Other platforms

| Platform | Finding | Label |
|---|---|---|
| Snapchat | No business direct-message API found. Snap Kit covers login and creative sharing; the public profile APIs cover content. | UNRESOLVED; **no integration possible on current evidence** |
| Google Business Messages | Believed discontinued in 2024 | ASSUMPTION (not checked officially this round) |
| SMS | Not researched; possible later for order notifications, but cost and sender ID rules in Iraq are unknown | UNRESOLVED |
| Others named by sellers | Captured by the "other" field in [J](j-seller-interview-questionnaire.md), then researched | — |

## 9. Cross-cutting conclusions (for the owner, not a selection)

1. **Every target platform except Telegram needs a provider-level approval or contract held by Aisellia**:
   - Meta App Review and Business Verification;
   - WhatsApp Tech Provider;
   - a Viber commercial contract;
   - TikTok developer reviews.

   These are **on the critical path for public launch**, and their eligibility for the owner's legal entity is UNRESOLVED.
2. **Costs differ structurally:**
   - WhatsApp charges per message beyond a free tier (VERIFIED);
   - Viber charges per bot per month (VERIFIED);
   - Telegram is free (VERIFIED);
   - Instagram, Messenger and TikTok costs are UNRESOLVED.

   A billing model must handle pass-through.
3. **Regulatory volatility in Iraq is real:** a federal Telegram suspension in 2026 (news). The provider suspension switch (L §6) and the manual paths matter.
4. **Unified-inbox features must follow capabilities:** reply windows, receipts and media differ (L §4).
