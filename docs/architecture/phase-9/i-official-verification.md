# I. Official-source verification (owner condition 7)

**Method and its limit:**
- **2026-10-17:** the official developer sites (developers.facebook.com, business.whatsapp.com, whatsapp.com, core.telegram.org) are **blocked by this environment's network policy**, so no page could be opened directly.
- Verification used web searches **restricted to those official domains**. The facts below are the search index's extracts of the official pages.

| Status | Meaning |
|---|---|
| **Confirmed (official, via index)** | An official page states it, as extracted by the search index; not read directly |
| **Partly confirmed** | An official page supports part of it; the rest is open |
| **Unverified** | No official statement found |
| **Changed** | Differs from what [B](b-channel-comparison.md) said on its first version |

**Before implementation:** one person reads every row's source page directly, from a normal network, and records the date read. Or the environment's network allow-list is extended to these domains so it can be re-done here.

## 1. WhatsApp Business Platform

| # | Item | Finding | Status | Source |
|---|---|---|---|---|
| W1 | **Service messages (free-form replies inside the 24 h window)** | **Charged per message since 2026-10-01.** Each business phone number gets **1,000 free service messages per month**, with no rollover. Without a payment method, Meta stops delivering service messages once the free tier is used. Utility templates sent inside the window are also charged again. | **Confirmed. Changed:** B previously cited the March 2026 page saying they were free | developers.facebook.com/documentation/business-messaging/whatsapp/pricing; …/pricing/non-template-messages |
| W2 | Iraq rates | Iraq is now a **named market** on the rate card (it left "Rest of Middle East" from October 2026). **The amounts were not retrieved.** Charges depend on the recipient's country code and apply on delivery. | Partly confirmed; **rates unverified** | Same pricing page; the rate card download |
| W3 | Customer-service window | 24 h, reset by each customer message. Outside it, only templates. | Confirmed | Pricing page; …/messages/send-messages |
| W4 | Free entry point (Click-to-WhatsApp ads) | 72 h, with one page saying up to 7 days | Partly confirmed (conflicting) | Pricing page |
| W5 | Business eligibility | Businesses in Cuba, Iran, North Korea, Syria and three Ukrainian regions are ineligible. **Iraq is not on that list.** | Confirmed | …/whatsapp/support |
| W6 | **Coexistence** (same number in the WhatsApp Business app and the Cloud API) | Requires app version ≥ 2.24.17, a **Tech Provider or Solution Partner** status, and Embedded Signup with session logging. **Shared numbers are capped at 20 messages per second.** Several app features are disabled after onboarding (disappearing and view-once messages, live location; groups and calls are not on the API side). App-sent messages do not count toward the API window. | Confirmed | …/embedded-signup/onboarding-business-app-users |
| W7 | **Coexistence for Iraqi numbers** | The changelog lists supported regions: Australia, Japan, Philippines, Russia, South Korea, Turkey, EEA / EU, UK, India, and from April 2026 Nigeria and South Africa. **Iraq is not listed.** | **Unverified; likely not available.** If so, a seller must use a separate number for the Cloud API. | …/whatsapp/changelog |
| W8 | Embedded Signup versions | Versions 2 and 3 were deprecated on 2026-10-15; use v4 | Partly confirmed | …/embedded-signup/implementation |
| W9 | Tech Provider path | Business verification, then app review; advanced access to `whatsapp_business_management` is needed to act on clients' accounts | Confirmed | …/solution-providers/get-started-for-tech-providers; …/solution-providers/app-review |
| W10 | Webhook retries | Failed deliveries are retried with decreasing frequency **for up to 7 days**, and **duplicates can occur**. One message can produce both "delivered" and "failed" statuses (multiple devices). Messages are dropped after their time-to-live. | Confirmed | …/whatsapp/webhooks/overview; …/throughput |
| W11 | Webhooks in development mode | **Some webhooks are not sent while the app is in Dev mode** | Confirmed | …/whatsapp/support |
| W12 | Test number | Created automatically with a test business account; relaxed limits; **no payment method needed** | Confirmed | …/about-the-platform |
| W13 | Test recipients limited to 5 | Not found on the official pages this time | **Unverified** (third-party only) | — |
| W14 | Throughput | 1 message per 6 s to the same user (error 131056). A new portfolio starts at 250 unique recipients per 24 h and 2 registered numbers. | Confirmed | …/throughput; …/messaging-limits; …/phone-numbers |
| W15 | **AI under the Business Solution Terms** | **AI providers** whose AI is the primary functionality are prohibited. Businesses **may** use automation and third-party AI, **with prompt, clear escalation paths to humans**. Business Solution Data **must not be used to train or improve AI models**, except fine-tuning for the business's exclusive use. | Confirmed (terms text via index). **Legal review needed** of how Aisellia, a vendor serving many sellers, is classified. | whatsapp.com/legal/business-solution-terms; business.whatsapp.com/policy |

## 2. Instagram Messaging (Instagram API with Instagram Login)

| # | Item | Finding | Status | Source |
|---|---|---|---|---|
| I1 | Access levels | **Standard Access** covers accounts you own or manage that are added to the app. **Advanced Access** is required to serve accounts you do not own. | Confirmed | developers.facebook.com/docs/instagram-platform/overview |
| I2 | Review and verification | **Advanced Access requires App Review and Business Verification** | Confirmed | Same |
| I3 | Permissions | `instagram_business_basic` and `instagram_business_manage_messages` (the new names of the `business_*` scopes). Review needs a screencast of login plus a message sent and shown in the Instagram inbox. | Confirmed | …/instagram-api-with-instagram-login; permissions reference |
| I4 | Reply window | 24 h from the customer's message. **Human Agent tag: up to 7 days** (deferred to Phase 9b by the owner). Self-messaging is exempt. | Confirmed | …/instagram-api-with-instagram-login/messaging-api |
| I5 | Echoes and reads | Echoes of the business's own sent messages arrive **in the `messages` webhook field** (there is no separate echo field on Instagram); `messaging_seen` gives read receipts | Confirmed. This supports reconciliation of unknown sends. | messenger-platform/webhooks; Instagram webhooks reference |
| I6 | Rate limits | 300 calls per second per professional account for text, link, reaction and sticker messages | Confirmed | messenger-platform/overview/rate-limiting |
| I7 | Tokens | Short-lived (1 h) tokens are exchanged server-side for **60-day** tokens. A refresh is possible once a token is at least 24 h old. **A token unrefreshed for 60 days cannot be refreshed.** | Confirmed | instagram-platform/reference/refresh_access_token; access_token |
| I8 | **Per-message price** | No official pricing statement found for replies inside the window | **Unverified.** Do not state "free" until confirmed. | — |
| I9 | Maximum text length | Not found | **Unverified** | — |
| I10 | Webhook subscription call for Instagram Login apps | Not confirmed (account-level or Page-level) | **Unverified** | — |
| I11 | Requests folder | Threads inactive for 30 days in Requests are not returned by the API | Confirmed | messaging-api page |
| I12 | Eligibility of Iraqi businesses for Business Verification | No official list found | **Unverified** | facebook.com/business/help/2058515294227817 (process only) |

## 3. Meta platform (both channels)

| # | Item | Finding | Status | Source |
|---|---|---|---|---|
| M1 | Signature | `X-Hub-Signature-256`: HMAC-SHA256 with the app secret over the payload **as sent, which escapes Unicode** (`ä…`, lowercase hex), so verify on the **raw bytes**. During secret rotation, accept either secret. | Confirmed | messenger-platform/webhooks |
| M2 | Response time and failures | Webhook calls time out after **20 s**, so respond first and process asynchronously. **Persistent failures unsubscribe the app**, and re-subscription is needed. | Confirmed (Messenger FAQ) | messenger-platform/faq |
| M3 | Verification handshake | `hub.mode`, `hub.verify_token`, `hub.challenge` | Not re-found this time; widely documented | **Unverified this round** |
| M4 | Development mode | Only users with a role on the app can use it, with data only from other role holders. Testers can grant any permission in development. | Confirmed | docs/apps/security; build-and-test/app-roles |
| M5 | App Review before Live | Advanced permissions need App Review; finish review before going Live | Confirmed | developers.facebook.com/blog/post/2019/09/23/live-mode-for-production-use |
| M6 | Data deletion | A data-deletion **instructions URL or callback** is required to publish | Confirmed | pages-api/create-an-app (publish checklist) |

## 4. Telegram (test harness only)

| # | Item | Finding | Status | Source |
|---|---|---|---|---|
| T1 | Webhook secret | `secret_token` (1–256 characters, A–Z a–z 0–9 _ -), returned in `X-Telegram-Bot-Api-Secret-Token` | Confirmed | core.telegram.org/bots/api |
| T2 | Business connections | `business_connection`, `business_message` updates; `sendMessage` accepts **`business_connection_id`**; rights include `can_reply` for chats with incoming messages in the last 24 h | Confirmed | core.telegram.org/bots/api; api-changelog |
| T3 | Telegram Business price or Premium requirement | Not found on official pages | **Unverified** | — |

## 5. Effect on the design

1. **WhatsApp now costs money for ordinary replies** (W1), beyond 1,000 per number per month, at Iraq rates not yet known (W2).
   - Each seller's account needs a payment method, or replies stop after the free tier. Who pays, the seller or Aisellia, is a new owner decision.
   - The adapter must surface "free tier exhausted / payment needed" as a connection state.
2. **Coexistence is probably unavailable for Iraqi numbers** (W7). A seller who wants to keep using the WhatsApp Business app on their number may not be able to connect it. This is a key interview question (J).
3. **The WhatsApp terms require clear human escalation paths and forbid using the data to train models** (W15). Aisellia's design already escalates to the seller and sends nothing automatically. Anthropic's API terms state API data is not used for training (Phase 8.5 C). **Legal review** of the AI-provider clause is still needed.
4. **Instagram:**
   - Advanced Access means **App Review and Business Verification** before any real seller (I1, I2).
   - Development mode with role accounts is the confirmed sandbox (M4).
   - Echoes in the `messages` field support the unknown-send reconciliation (I5).
   - **Pricing is unverified** (I8).
5. **Meta webhooks unsubscribe after persistent failures** (M2). The health check must detect silence and re-subscribe, which is now in [E](e-reliability.md).
6. **WhatsApp dev mode suppresses some webhooks** (W11). The staging test may need the app in Live mode with test assets, which needs a decision at that point.

**Sources (official domains, via search index, 2026-10-17):**
- [WhatsApp pricing](https://developers.facebook.com/documentation/business-messaging/whatsapp/pricing)
- [Non-template pricing updates](https://developers.facebook.com/documentation/business-messaging/whatsapp/pricing/non-template-messages)
- [Onboard WhatsApp Business app users](https://developers.facebook.com/documentation/business-messaging/whatsapp/embedded-signup/onboarding-business-app-users/)
- [WhatsApp changelog](https://developers.facebook.com/documentation/business-messaging/whatsapp/changelog)
- [WhatsApp webhooks](https://developers.facebook.com/documentation/business-messaging/whatsapp/webhooks/overview/)
- [Throughput](https://developers.facebook.com/documentation/business-messaging/whatsapp/throughput)
- [WhatsApp support](https://developers.facebook.com/documentation/business-messaging/whatsapp/support)
- [About the platform](https://developers.facebook.com/documentation/business-messaging/whatsapp/about-the-platform)
- [Messaging limits](https://developers.facebook.com/documentation/business-messaging/whatsapp/messaging-limits)
- [Tech Provider](https://developers.facebook.com/documentation/business-messaging/whatsapp/solution-providers/get-started-for-tech-providers)
- [WhatsApp Business Solution Terms](https://www.whatsapp.com/legal/business-solution-terms)
- [WhatsApp Business Policy](https://business.whatsapp.com/policy)
- [Instagram Platform overview](https://developers.facebook.com/docs/instagram-platform/overview/)
- [Instagram Login messaging](https://developers.facebook.com/documentation/instagram-platform/instagram-api-with-instagram-login/messaging-api)
- [Refresh access token](https://developers.facebook.com/docs/instagram-platform/reference/refresh_access_token/)
- [Messenger webhooks](https://developers.facebook.com/documentation/business-messaging/messenger-platform/webhooks)
- [Messenger FAQ](https://developers.facebook.com/documentation/business-messaging/messenger-platform/faq)
- [Messenger rate limits](https://developers.facebook.com/documentation/business-messaging/messenger-platform/overview/rate-limiting)
- [App roles](https://developers.facebook.com/documentation/development/build-and-test/app-roles)
- [App security and modes](https://developers.facebook.com/docs/apps/security)
- [Live mode for production](https://developers.facebook.com/blog/post/2019/09/23/live-mode-for-production-use/)
- [Publish checklist](https://developers.facebook.com/documentation/pages-api/create-an-app)
- [Business verification](https://www.facebook.com/business/help/2058515294227817)
- [Telegram Bot API](https://core.telegram.org/bots/api)
- [Telegram Bot API changelog](https://core.telegram.org/bots/api-changelog)
