# J. Seller interview: which messaging platforms matter, and in what order?

**Revision 2:** this covers every target platform plus "other". It replaces the Instagram-vs-WhatsApp version at commit `61833a3`.

**Purpose:** learn where sellers find customers and finalise orders, so the owner can choose the **order of provider integrations**.
- The research matrix ([M](m-platform-matrix.md)) and any score are inputs, not the decision.
- **No platform is selected by this document.**

## 1. Who and how

**Initial discovery: at least 5 sellers.** This is the existing minimum. It is enough to find the dominant patterns and surprises, not to size a market.

**Why broader validation is needed before a public launch:**
- **Five sellers cannot represent many.** Categories (clothing, cosmetics, electronics, food), cities (Erbil, Sulaymaniyah, Duhok, Halabja, others), seller size, and language mix (Sorani, Badini, Arabic) will differ.
- A public launch commits Aisellia to provider approvals and contracts, to per-provider costs (WhatsApp per message, Viber per bot), and to support for each provider. A wrong order is expensive.
- **Proposed second stage, before public launch:** a short structured survey (sections A, B, D and F below, multiple choice) with **at least 30 sellers** across categories and the three governorates, plus follow-up interviews with sellers whose answers differ from the first five. Sample sizes are an ASSUMPTION, to be confirmed by the owner.

**Format:**
- 20–25 minutes, in Sorani, Badini, Arabic or English, as the seller prefers.
- A native interviewer translates the meaning; the Sorani and Arabic wording needs native review.
- **Notes only:** no customer names, phone numbers, account handles, screenshots or message text.

**Consent line (read first):** "We are asking how you sell, to decide which apps Aisellia should connect to and in which order. We won't record any customer's details or your passwords. You can skip any question or stop at any time."

## 2. Questions

The platforms are referred to by these codes:

| Code | Platform |
|---|---|
| IG | Instagram |
| WA | WhatsApp |
| FB | Facebook Messenger |
| TG | Telegram |
| VB | Viber |
| TT | TikTok |
| SC | Snapchat |
| PH | Phone calls |
| OT | Other: write the name |

**A. Where customers come from and where orders close**
1. Where do customers first **discover** your products? Rank the top three (IG, WA, FB, TG, VB, TT, SC, other, and offline or word of mouth).
2. Where do customers **message** you? Approximately how many conversations per week on each? (0 / 1–10 / 11–50 / 51–200 / 200+)
3. Where are orders **finalised**, meaning price, size, address and payment agreed? Of your last 10 orders, how many on each platform?
4. Do customers move between apps during one order (for example TikTok → WhatsApp)? At what point, and why?
5. Approximately how many **orders per week** do you take in total? In your busiest week?

**B. Accounts and willingness to connect**
6. For each platform you use for selling, what account type do you have?
   - IG: professional (business or creator) or personal;
   - FB: Page or profile;
   - WA: Business app or ordinary WhatsApp, on a shop or personal number;
   - TG: bot, business account or personal;
   - VB: bot / business or personal;
   - TT: business or personal.
7. Who can log in to each account? Is any shared with staff or family?
8. Would you connect each account to Aisellia so messages appear in one inbox? (Yes / Maybe / No for each.) Why not, where No?
9. For WhatsApp: would you use a **separate business number** if your current number could not be connected? (Sharing a number with the WhatsApp Business app is probably unavailable in Iraq: [M §3](m-platform-matrix.md#3-whatsapp-business-platform-cloud-api).)
10. For Telegram or Viber: would your customers message a **shop bot** instead of you personally?

**C. Features and languages**
11. Which features matter most? Rank them:
    - one inbox for all apps;
    - suggested replies;
    - order drafts from chats;
    - order status messages;
    - reply-time reminders;
    - seeing photos and voice notes;
    - working with staff.
12. Do customers send **voice notes** or **photos** more than text? On which platform? (Early versions show these as placeholders only.)
13. Which languages and scripts do customers write in (Sorani in Arabic script, Sorani in Latin script, Badini, Arabic, English, mixed)?
14. Do you ever reply more than 24 hours after a customer's last message? How often? (Several platforms block free replies after 24 h.)

**D. Willingness to pay**
15. Would you pay a monthly subscription for Aisellia? Roughly how much is reasonable? (Ranges in IQD; the owner sets them.)
16. Some platforms charge per message (WhatsApp beyond a free monthly allowance) or per month (Viber bots). Should such costs be **included** in the price, **passed through** at cost, or would that make the platform not worth connecting?

**E. Security and privacy**
17. What worries you about connecting your accounts (losing access, account bans, privacy, staff misuse, cost surprises)?
18. Are you comfortable with an AI **suggesting** replies, as long as you review and tap Send on every message and nothing is sent automatically?
19. Would your customers expect to be told that a tool helps you reply?

**F. Priorities**
20. If Aisellia could connect only **one** platform first, which would save you the most time? Second? Third?
21. Is there any platform not listed that you or your customers use for selling? (Other)

## 3. Results sheet (one per seller)

| Field | Answer |
|---|---|
| Seller code (no name), category, city, team size | |
| Interview language | |
| Weekly conversations: IG / WA / FB / TG / VB / TT / SC / PH / other | |
| Last 10 orders finalised on: IG / WA / FB / TG / VB / TT / other | |
| Orders per week (typical / peak) | |
| Account types per platform | |
| Willing to connect (Y / M / N) per platform, with the reason for N | |
| WhatsApp: would use a separate number? Telegram or Viber: customers would use a bot? | |
| Top 3 features (Q11) | |
| Voice notes or photos heavy? On which platform? | |
| Languages and scripts | |
| Replies after 24 h: never / sometimes / often | |
| Subscription willingness (range); provider costs included / passed through / deal-breaker | |
| Main security or privacy concern | |
| AI suggestion comfort (Y / M / N) | |
| Priority 1 / 2 / 3 platform | |
| Other platforms named | |

## 4. Aggregation sheet (across sellers, filled by the owner or interviewer)

| Platform | Sellers using it for selling | Sellers finalising most orders there | Sellers willing to connect | Rank-1 votes | Blocking concerns |
|---|---|---|---|---|---|
| IG | | | | | |
| WA | | | | | |
| FB | | | | | |
| TG | | | | | |
| VB | | | | | |
| TT | | | | | |
| Other | | | | | |

## 5. How the results feed the decision (qualitative, owner decides)

For each platform, combine three things:
- **seller demand**: finalised orders, rank-1 votes, willingness to connect;
- **feasibility**: the evidence in [M](m-platform-matrix.md), with the UNRESOLVED items resolved or accepted;
- **cost and approval effort**.

A platform is a candidate for the first integration only if:
- sellers would connect it;
- Aisellia can obtain the provider approval for its legal entity;
- its cost model is acceptable.

**"None yet"** is a valid outcome: sellers keep the manual paste-in inbox.
