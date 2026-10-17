# B. Channel comparison and recommendation

**Confidence labels:**
- **[O]** official documentation, as reported by search on 2026-10-17;
- **[T]** third-party provider or press;
- **[U]** unverified or conflicting.

The official sites could not be opened directly from this environment, so **every row must be re-verified on the official page before implementation** (§5).

## 1. Where Kurdistan Region customers are

The only recent figures found come from an Ipsos survey published September 2025 (Iraq; via intaj.net) **[T]**. In the Kurdistan Area:

| Platform | Share of users |
|---|---|
| Facebook | 68% |
| Instagram | 67% |
| WhatsApp | 66% |
| Snapchat | 63% |

Iraq-wide, WhatsApp reaches 74%. Viber has a long-standing user base in the region and offers a Sorani interface **[T, older]**. Telegram is widely used in Iraq, but the data found measures website integrations, not users **[T]**.

**No data was found on which channel Kurdistan sellers take orders on.** That is the M0 interview question behind Phase 1 D-02, and it should decide the final choice (§4).

## 2. Comparison

| | WhatsApp Business Platform (Cloud API) | Instagram Messaging (Instagram API with Instagram Login) | Messenger Platform | Telegram Bot API | Viber Bot API |
|---|---|---|---|---|---|
| **Who the customer writes to** | The seller's business number. With **coexistence**, the same number keeps working in the WhatsApp Business app **[T]**. | The seller's existing Instagram professional account (DMs) **[O]** | The seller's Facebook Page | A **bot** the seller creates, not the seller's own account. Telegram Business can connect a bot to a business account, but it is paid / Premium functionality **[T, U]** | A bot (business "chatbot") |
| **Fit for Kurdistan sellers** | High: order-taking channel | High: discovery channel; DMs start here | Medium | Low–medium: customers must adopt a bot | Medium: real user base, but bot-only and paid |
| **Approval to serve other businesses** | Business verification, app review, and **Tech Provider** onboarding through Embedded Signup. Advanced access to `whatsapp_business_management` is needed to act on clients' accounts **[O via search]**. Display-name review and phone-number registration per seller. | App review for `instagram_business_basic` and `instagram_business_manage_messages` with **Advanced Access** to serve accounts that are not app roles **[O]**. Screencast of the flow expected **[T]**. Business verification likely required for Advanced Access **[U]**. | Similar Meta app review (`pages_messaging`) **[U]** | None. A token from BotFather **[O]**. | Commercial terms with Viber; resellers add validation and activation fees **[T]** |
| **Reply window** | 24 h customer-service window from the customer's last message; templates needed outside it **[O]** | 24 h standard window. The **Human Agent** tag allows human replies up to **7 days**; it requires a permission and is not for automated messages **[O for the tag, T for 7 days]** | 24 h plus message tags (no promotions under tags) **[O]** | No platform window found for replies to user-initiated chats **[U]** | 24 h session from the user's message; bot-initiated messages are charged **[T]** |
| **Cost per message** | Per-message pricing by category and market. Meta's page (updated 2026-03-30) says non-template messages inside the window are free **[O]**. Several providers say service messages are **charged from 2026-10-01**, with 1,000 free per number per month, at about USD 0.0068 per message in their tables **[T, U, conflicting]**. **Iraq rates not retrieved.** | No per-message fee found **[U]** | No per-message fee found **[U]** | Free **[O]** | **EUR 100 per bot per month** plus bot-initiated messages, for bots created since 2024-02-05 **[T]** |
| **Throughput and limits** | 80 messages per second per number by default; **1 message per 6 s to the same user** (error 131056) **[O via search]**. Unique-user limits per business portfolio (250 / 2,000 / 10,000 / 100,000 per 24 h) **[T]**. | Send API 300/s per account for text; Conversations API 2/s; too many messages to one thread can be limited **[O]** | Meta Messenger rate limits **[O]** | Bot API limits (about 30 messages/s overall, 1/s per chat in common guidance) **[U]** | Provider limits **[U]** |
| **Webhook authenticity** | `X-Hub-Signature-256` = HMAC-SHA256 of the **raw body** with the app secret; `hub.verify_token` and `hub.challenge` handshake **[O / T]** | Same Meta mechanism **[O]** | Same **[O]** | `secret_token` from `setWebhook`, echoed in `X-Telegram-Bot-Api-Secret-Token` (1–256 chars, A–Z a–z 0–9 _ -) **[O]** | `X-Viber-Content-Signature`: HMAC-SHA256 with the auth token **[U]** |
| **Delivery semantics** | At-least-once, no ordering guarantee; retries with backoff for up to **7 days**; a 200 is expected within about 5–10 s **[T]** | Meta webhooks, at-least-once **[U]** | Same **[U]** | Telegram retries unacknowledged updates **[U]** | **[U]** |
| **Sandbox** | **Free test number and test WhatsApp Business Account**, up to **5 verified recipient numbers**, no payment method needed. Test numbers cannot message real customers, and their templates do not carry over **[O]**. | An app in development mode with **Standard Access** works for professional accounts that have a role on the app: our own test account **[O]** | A test Page with app-role users **[U]** | A free test bot **[O]** | A test bot, but subject to the commercial model **[T]** |
| **Policy notes** | Since **2026-01-15**, the WhatsApp Business Solution terms bar **general-purpose** AI assistants. Business-specific customer-service AI is allowed, and Meta decides what is "primary" **[T, press]**. Aisellia is a business-specific assistant whose replies are sent by the seller. | Disclose automated experiences; Human Agent tag only for humans **[T / O]** | No promotions under message tags **[O]** | — | — |
| **Build effort** | High: Embedded Signup, Tech Provider, templates for out-of-window confirmations | Medium: OAuth (Instagram Login), webhooks, Send API | Medium | Low | Medium |

## 3. Scoring

Weighted for the Phase 9 goal: reduce copy-paste for pilot sellers safely, at low cost and approval risk.

| Criterion (weight) | WhatsApp | Instagram | Messenger | Telegram | Viber |
|---|---|---|---|---|---|
| Seller and customer fit (30) | 5 | 5 | 3 | 2 | 3 |
| Approval risk and time (20) | 2 | 3 | 3 | 5 | 2 |
| Cost predictability (15) | 2 | 4 | 4 | 5 | 1 |
| Sandbox quality without real customers (15) | 4 | 4 | 3 | 5 | 2 |
| Build effort (10) | 2 | 3 | 3 | 5 | 3 |
| Policy risk for an AI-assisted product (10) | 3 | 4 | 4 | 5 | 3 |
| **Weighted score (out of 5)** | **3.30** | **4.00** | **3.25** | **4.10** | **2.35** |

Telegram scores well only because it is easy. Its weak fit, where customers must find and message a bot, makes it a poor **first customer channel** for Kurdistan shops.

## 4. Recommendation

1. **First live channel: Instagram Messaging (Instagram API with Instagram Login)**, **conditional on M0 confirming** that pilot sellers' orders mostly start in Instagram DMs.
   - It is where Kurdistan shoppers discover products.
   - No per-message fee was found.
   - No phone-number migration.
   - It is testable end to end in development mode with our own test professional account, before any app review.
   - App review is needed only before real sellers connect.
2. **Second: WhatsApp Cloud API**, after three things are verified:
   - Iraq rates and whether service messages are now charged;
   - coexistence availability for Iraqi numbers;
   - Tech Provider approval.

   **If M0 shows WhatsApp is where orders are taken, swap the order.** The architecture ([C](c-integration-architecture.md)) is channel-agnostic, and WhatsApp's free test number makes its sandbox work equally well.
3. **Telegram: a test harness only, optional.** A free bot can exercise the staging webhook, send and reconciliation path with team accounts at no cost. It is not offered to sellers in Phase 9.
4. **Messenger and Viber: not in Phase 9.** Messenger shares Instagram's Meta plumbing and can follow cheaply later. Viber's monthly fee per bot is not justified for a pilot.

**Owner decision (D-02, Phase 9):**
- confirm the first channel after the M0 seller interviews;
- approve creating a Meta developer app and test assets (§5, G).

## 5. To verify on official pages before implementation

1. Instagram: the exact permission names, whether Advanced Access requires business verification, and the Human Agent tag's permission and window.
2. Instagram and Messenger: whether there is any per-message charge; whether echo events of our own sends arrive, which matters for reconciliation.
3. WhatsApp:
   - the current pricing for service messages (the 2026-03-30 official page and the 2026-10-01 third-party claims disagree), and the Iraq rate card;
   - coexistence country support;
   - Tech Provider requirements and timeline;
   - webhook retry window.
4. Meta: business verification with an Iraqi or other legal entity. **Which legal entity will own the Meta app is an owner decision.**
5. Telegram: whether `sendMessage` accepts a `business_connection_id`, and Telegram Business pricing.
6. All: platform terms on storing message content and on using AI to draft replies; data-deletion callback requirements (Meta requires a data-deletion endpoint or instructions for apps **[U]**).

**Sources found by search on 2026-10-17:**
- Meta / WhatsApp pricing and throughput: developers.facebook.com/documentation/business-messaging/whatsapp/pricing; …/whatsapp/throughput.
- Meta / Instagram Login messaging: developers.facebook.com/documentation/business-messaging/messenger-platform/overview/rate-limiting; …/policy.
- Meta / WhatsApp test numbers and Tech Provider: developers.facebook.com/docs/whatsapp/cloud-api/get-started; …/solution-providers/get-started-for-tech-providers.
- Telegram: core.telegram.org/bots/api.
- Third parties: respond.io and wati.io (WhatsApp 2026 pricing); hookdeck.com (Meta webhook signature and retries); 360dialog and telnyx (coexistence); TechCrunch, 2025-10-18 (WhatsApp AI chatbot terms); SleekFlow and respond.io (Viber commercial model); intaj.net Ipsos Iraq survey, September 2025.
