# L. Provider-neutral multi-channel architecture (public launch)

**Status:** design proposal for review; **not approved, not authorized**. Documentation only: no code, migration or configuration has changed.

**Scope change:**
- **Before:** one first channel for a pilot of a few sellers.
- **Now:** a **public launch for many sellers**, with one unified inbox in the Flutter app, and providers added **one at a time**.

**What is kept:** the security, reliability and seller-control decisions in [C](c-integration-architecture.md)–[F](f-seller-sending-workflow.md) and the owner's ten conditions ([README](README.md)).

**What this document changes:**
- generalizes the channel-specific pieces of C into a provider-neutral core;
- adds a capability registry;
- states what public multi-tenant operation needs.

| Kept from C–F unchanged | Changed here |
|---|---|
| Separate least-privilege ingest and sender login roles; no service-role key in functions | `channel` check constraint → a **provider registry**; adding a provider adds a registry row and an adapter, not a schema redesign |
| Raw-body webhook verification before parsing | Verification is a per-provider adapter method with a shared contract and test kit |
| Store resolved from the verified account id, never the URL; one active connection per provider account | Webhook routing generalized: `/channel-webhook/<provider>` plus an optional per-connection path, for providers whose secret is per bot |
| Two-level deduplication (event, message), backoff, replay, 14-day payloads | Queue partitioned per provider and connection, so one noisy tenant or provider cannot starve others |
| Seller-authorized exact text (hash check), no automatic resend of unknown outcomes | Delivery states mapped from each provider into one common state machine |
| AI opt-in, off by default; AI never sends or approves; confirmations only for approved orders | Capabilities gate the UI and the server: no feature is offered on a provider whose registry entry lacks it |
| Vault-held per-connection tokens | Credential types per provider (OAuth refresh, long-lived token, bot token, partner-issued token) with rotation metadata |

## 1. Layers

```
 Flutter app (one unified inbox)
   │   reads conversations/messages through membership-scoped functions; sends only via api.send_message
   ▼
 Core (Postgres, provider-neutral)
   connections · contacts · conversations · messages · attachments · send_requests · delivery_events
   provider_registry · provider_capabilities · webhook_events · limits · audit
   │                                   ▲
   │ normalized commands               │ normalized events
   ▼                                   │
 Adapter layer (Edge Functions, one module per provider, shared test kit)
   instagram · whatsapp · messenger · telegram · viber · tiktok · <future>
   │ verify / parse / send / status / connect / refresh / disconnect
   ▼
 Provider APIs and webhooks
```

**Rule:** the core never contains provider names in business logic. Behaviour that differs by provider is expressed as a **capability** read from the registry. Code paths that need provider specifics live only in adapters.

## 2. Common data model

These tables replace the channel-specific sketch in C §2. Names are provider-neutral, and every table carries `store_id` with composite foreign keys.

| Table | Purpose | Key constraints |
|---|---|---|
| `app.providers` | Registry: `id` (instagram, whatsapp, messenger, telegram, viber, tiktok, …), `status` (`planned`, `in_development`, `pilot`, `available`, `suspended`), `adapter_version`, `released_at` | Only operators change it. The app hides providers that are not `pilot` or `available` for the seller. |
| `app.provider_capabilities` | One row per (provider, capability key), with a typed value and the evidence label (VERIFIED, ASSUMPTION or UNRESOLVED) and source URL | See §4. An `UNRESOLVED` capability is treated as **absent**. |
| `app.connections` | A seller's account on a provider: `provider`, `external_account_id`, `state`, `credential_ref` (Vault id), `credential_kind`, `expires_at`, `scopes`, `is_test`, health fields | Partial unique `(provider, external_account_id)` where not disconnected |
| `app.contacts` | A customer as seen on one connection: `external_user_id`, display name (untrusted), optional phone (WhatsApp), `window_expires_at`, `blocked` | Unique `(connection_id, external_user_id)` |
| `app.conversations` (existing, extended) | `connection_id`, `contact_id` for live threads; `source` and `is_sandbox` unchanged for manual and sandbox | A sandbox conversation never has a connection. A conversation and its connection share a store. |
| `app.messages` (existing, extended) | Origins `channel_in`, `seller_sent`, `seller_external`; delivery state; `external_message_id` | Unique `(connection_id, external_message_id)` |
| `app.message_attachments` | Type (image, video, audio, voice, file, sticker, location, contact, other), provider reference, MIME type, size; **no download in the first releases** | Stored as references; retention as messages |
| `app.send_requests` | Seller authorization: actor, time, text SHA-256, suggestion link, kind (reply / order confirmation), state, attempts, provider message id | Unique `(store_id, idempotency_key)`; one per outbound message |
| `app.delivery_events` | Provider status events mapped to common states, keeping the provider's raw status code | Unique `(connection_id, provider_event_key)` |
| `app.webhook_events` | Raw verified events for 14 days; processing status | Unique `(provider, external_event_id)` |

**Common delivery states:** `queued → sending → sent → delivered → read`, plus `failed` and `unknown`.
- Each adapter maps its provider's codes. Providers that report fewer states simply never emit the missing ones.
- The app shows only the states the provider supports. Capability `delivery_receipts` and `read_receipts` decide this.

## 3. Shared adapter interface

This evolves C §3; the shape is the same, with the provider union removed.

```ts
interface ProviderAdapter {
  readonly provider: string;                       // registry id
  readonly manifest: CapabilityManifest;           // static, versioned, reviewed with evidence labels (§4)
  handshake?(req: Request): Response | null;       // e.g. Meta hub.challenge
  verify(raw: Uint8Array, headers: Headers, secrets: AppSecrets, conn?: ConnectionSecrets): VerifyResult;
  route(payload: unknown): { accountIds: string[] };            // which connection(s) an event is for
  parse(payload: unknown): NormalizedEvent[];                   // message, echo, delivery, read, account, unknown
  send(cmd: OutboundCommand, cred: Credential, opts: { timeoutMs: number }): Promise<SendResult>;
  status?(providerMessageId: string, cred: Credential): Promise<StatusResult>;  // only if the provider has a lookup
  connect: ConnectFlow;                            // oauth | partner_signup | bot_token | manual
  refresh?(cred: Credential): Promise<Credential>; // only for expiring credentials
  disconnect(cred: Credential): Promise<void>;     // best-effort revoke; webhook removal where applicable
}
type OutboundCommand = { kind: "text"; text: string; textSha256: string; recipient: string; replyTo?: string };
// Media sending is a later capability (`send_media`), added per provider only when verified.
```

Every adapter must pass the **shared conformance kit** before release:
- signature accept and reject;
- raw-body and Unicode handling;
- duplicate events;
- out-of-order receipts;
- timeout → `unknown`;
- 429 → retriable;
- exact text bytes reach the provider stub;
- no secrets in logs.

## 4. Capability registry

Capabilities are **declared per provider with evidence**, and both the server and the app enforce them.

| Capability key | Type | Meaning |
|---|---|---|
| `inbound_text` | bool | Customer text arrives by webhook |
| `inbound_media_types` | set | Which attachment types arrive (shown as placeholders until media handling exists) |
| `outbound_text` | bool | Free-form text replies through the API |
| `send_media` | set | Media we may send (not used in the first releases) |
| `reply_window_hours` | int or null | Free-form reply window after the customer's last message; null = none documented |
| `outside_window` | enum | `none`, `templates`, `tags`, `paid_message` |
| `delivery_receipts`, `read_receipts`, `echoes` | bool | Status signals available |
| `status_lookup` | bool | A status query exists for unknown outcomes |
| `per_recipient_min_interval_ms` | int | Pacing to one customer |
| `account_rate_limit` | text | Documented limit, for the token bucket |
| `max_text_length` | int or null | Null = unknown, so the server applies a conservative cap |
| `connect_flow` | enum | `oauth`, `partner_signup`, `bot_token`, `manual` |
| `credential_expiry` | text | For example, 60 days with a refresh |
| `per_message_cost` | enum | `none_documented`, `charged`, `charged_outside_session`, `unknown` |
| `requires_payment_method` | bool | The seller or Aisellia must hold billing with the provider |
| `requires_platform_review` | text | App Review, partner review, commercial contract |
| `region_restrictions` | text | Known exclusions |

**Rules:**
1. A capability marked **UNRESOLVED counts as absent**. We do not promise it.
2. The send path checks capabilities on the server: window, outside-window mode, text length, pacing. The app only mirrors them.
3. A capability change is a reviewed registry update with a new evidence source, and it is audited.

**Genuinely common** across all target providers (§ matrix in [M](m-platform-matrix.md)):
- inbound text by webhook;
- outbound text reply to a customer who wrote first;
- a provider message id for sent messages;
- some form of request authentication.

**Not common, and therefore never assumed:**
- the same reply window (24 h on Meta and Viber sessions; none documented for Telegram; TikTok unresolved);
- delivery and read receipts;
- echoes of replies sent from the native app;
- status lookups;
- per-message cost;
- media types;
- whether a customer can start the conversation from a link;
- coexistence with the native business app.

## 5. Connections and credentials

| Provider kind | Connect flow | Credential storage | Rotation |
|---|---|---|---|
| Meta (Instagram, Messenger, WhatsApp) | OAuth / Embedded Signup with a signed `state` bound to (user, store, nonce, expiry) | Vault; the table holds the id | Instagram: refresh before 60 days (VERIFIED, I I7); others per provider |
| Telegram | Bot token pasted once into a write-only server form | Vault; webhook `secret_token` stored as a hash | Re-issue via BotFather; revoke on disconnect |
| Viber | Bot created under a commercial contract (VERIFIED); auth token per bot | Vault | Per Viber; contract-bound |
| TikTok | Authorization by each business account after Aisellia passes TikTok's developer reviews (VERIFIED) | Vault | Per TikTok token rules (UNRESOLVED) |

**App-level secrets** (Meta app secret, TikTok app secret, OAuth state key) live in Edge Function secrets, **one set per environment**, never in the database or app. Only the owner (`channels.manage`) connects or disconnects.

## 6. Ingestion, queues, idempotency, retries

These are as in C §4 and [E](e-reliability.md), generalized:
- **One webhook function per provider**, deployed separately, so a bug or flood in one adapter does not take down the others. Each uses the single ingest role.
- `webhook_events` is partitioned logically by provider. The processor claims batches **fairly per (provider, connection)** with a per-connection cap per cycle, so a noisy tenant cannot starve others.
- Idempotency, backoff, a failed state, replay and the 14-day payload purge apply to every provider.
- **Provider-level health:** signature failures, backlog, last event, and Meta-style "unsubscribed" detection. Each provider can be put in `suspended` in the registry, which pauses its sends and shows a banner without affecting other providers.

## 7. Unknown outbound outcomes

These are the same for all providers ([E §4](e-reliability.md#4-unknown-outcomes-and-reconciliation)):
- **never resent automatically**;
- reconciled via echoes, receipts or a status lookup **only where the capability exists**;
- otherwise surfaced to the seller.

Providers without echoes or lookups (capability-driven) go straight to "Sending status unknown" after the window.

## 8. Tenant isolation and roles

These are unchanged in principle ([D §2](d-security.md#2-tenant-isolation)), with two additions for scale:
- **Roles are per function, not per provider:** ingest, sender and ai_worker. Adding a provider adds no database privileges.
- **Per-tenant resource limits** (§9) prevent one seller from exhausting shared queues, AI budget or provider rate limits.

**pgTAP isolation suites become parameterized by provider:** every new provider runs the same cross-store, sandbox and forged-routing tests.

## 9. Rate limits and quotas (public multi-tenant)

| Level | Examples |
|---|---|
| Provider (platform-imposed) | Per account and per recipient limits from the registry, enforced by token buckets in `channel-send` |
| Tenant (store) | Connections per store; sends per minute and day; inbound events processed per cycle; AI runs and cost (existing brakes); attachment references |
| Plan (commercial) | Limits per pricing plan. Needs a plan table and billing integration; **new for public launch** |
| Platform-wide | Total AI cost brake (existing); per-provider send ceilings; global backlog alarms |

## 10. Monitoring, audit, privacy, retention

**Monitoring:** per provider and per connection:
- events received;
- processing lag;
- signature failures;
- send outcomes by state;
- `unknown` rate;
- token expiry;
- webhook silence.

Alerts route to an on-call owner. Dashboards are needed before public launch.

**Audit:** as in [E §6](e-reliability.md#6-audit-logging), plus registry and capability changes, provider suspension, and plan-limit changes. Every provider message id maps to a human `message.send_authorized` row.

**Privacy and retention:**
- **Per provider:** platform data-deletion obligations, such as the Meta data-deletion callback (VERIFIED, I M6), are handled by a common "provider deletion request" flow.
- **Common rules:** messages 12 months; payloads 14 days; contacts anonymisable by phone or by contact.
- Provider-specific terms that restrict storage or use (for example, the WhatsApp ban on using data to train models, VERIFIED, I W15) are recorded in the registry and the privacy policy.

## 11. Seller-controlled sending and approval gates (unchanged)

[F](f-seller-sending-workflow.md) applies to every provider:
- "Use this reply" → Send;
- exact-text hash;
- AI never sends;
- order confirmations only for approved orders by explicit Send;
- no auto-send, bulk send or scheduled send.

Outside-window mechanisms (templates, tags, paid messages) are **disabled for all providers** until a separate, owner-approved design covers them. That includes the Human Agent tag (Phase 9b).

## 12. Adding a provider: the checklist

1. Research entry in [M](m-platform-matrix.md), with evidence labels; legal and terms review; cost model approved by the owner.
2. Capability manifest with evidence, and the registry row in `planned`.
3. Adapter plus shared conformance kit plus provider-specific fixtures; local only.
4. Connect, disconnect and deletion flows; app strings in ckb / ar / en with native review.
5. Staging with team-owned test accounts (when authorized).
6. Registry → `pilot` for chosen sellers; then `available`.

**No core schema change is expected.** If one is needed, the design was wrong and is reviewed.

## 13. What public multi-tenant operation adds (beyond the pilot design)

| Area | Change needed | Why |
|---|---|---|
| Self-serve onboarding | Seller connects providers without operator help; guided flows; failure explanations in three languages | Many sellers |
| Platform approvals at scale | Meta Tech Provider / App Review, TikTok developer reviews, Viber commercial contract per bot: obtained **once by Aisellia**, before launch per provider | Cannot be done per seller |
| Billing and plans | Plans, quotas, and pass-through of provider message charges (WhatsApp, Viber) | Provider costs vary by seller volume |
| Fair queuing and isolation | Per-connection batch caps, per-provider functions, provider suspension switch | Noisy neighbours |
| Observability and on-call | Dashboards, alerts, runbooks, status page | Outages affect many sellers |
| Support access | Consented, audited, least-privilege support procedure (Phase 1 §5.1), with no in-app store data access | Support volume |
| Abuse and fraud | Seller verification level before connecting; spam detection on outbound; account suspension | Platform policies hold Aisellia responsible |
| Legal | Terms, privacy policy, data-processing terms with sellers, provider terms compliance, the AI provider clause review | Public service |
| Security | Secret rotation runbook, key management, a dependency and vulnerability process, penetration test before launch | Larger attack surface |
| Capacity | Load tests on ingestion and send queues at, for example, 100× pilot volume; Supabase plan sizing | Scale |
| Data residency | Region decision (AD-02) documented per provider's processing locations | Seller trust and law |

## 14. Phase 8.5 risks (still open, carried into every provider)

- **Real-model quality is untested.** The evaluation is blocked pending a dedicated staging key.
- **Native Sorani and Arabic review has not been done.**
- **No consented conversations have been collected.**
- **Fabricated non-numeric promises are not solved.** Live sending on any provider makes this more consequential.

Public launch of AI suggestions on any provider is blocked until these gates close ([Phase 8.5 H](../../implementation/phase-8.5/h-validation-gates-and-review.md)).
