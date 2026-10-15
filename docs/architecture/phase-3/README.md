# Aisellia — Phase 3 technical architecture

**Status:** Proposed — **pending owner approval**. No code, migrations, infrastructure or live integrations have been created in this phase.
**Baselines:** [Phase 1 product spec](../../product/phase-1-product-specification.md) (D-01–D-15 pending), [Phase 2 design spec](../../design/phase-2/README.md) (DD-01–DD-13 pending).

| # | Deliverable | File |
|---|---|---|
| 1 | Architecture overview | [architecture-overview.md](architecture-overview.md) |
| 2 | Technology decisions | [technology-decisions.md](technology-decisions.md) |
| 3 | Architecture decision records | [architecture-decision-records/](architecture-decision-records/README.md) |
| 4 | Flutter architecture | [flutter-architecture.md](flutter-architecture.md) |
| 5 | Backend and data model | [backend-and-data-model.md](backend-and-data-model.md) |
| 6 | Authorization and tenancy | [authorization-and-tenancy.md](authorization-and-tenancy.md) |
| 7 | API and service contracts | [api-and-service-contracts.md](api-and-service-contracts.md) |
| 8 | AI integration architecture | [ai-integration-architecture.md](ai-integration-architecture.md) |
| 9 | Messaging integration architecture | [messaging-integration-architecture.md](messaging-integration-architecture.md) |
| 10 | Security threat model | [security-threat-model.md](security-threat-model.md) |
| 11 | Testing and quality strategy | [testing-and-quality-strategy.md](testing-and-quality-strategy.md) |
| 12 | Deployment and operations | [deployment-and-operations.md](deployment-and-operations.md) |
| 13 | Pilot cost estimate | [pilot-cost-estimate.md](pilot-cost-estimate.md) |
| 14 | Implementation roadmap | [implementation-roadmap.md](implementation-roadmap.md) |
| 15 | Completion report | [phase-3-completion-report.md](phase-3-completion-report.md) |

**Design validation artifact:** [proofs/approval-consistency/](proofs/approval-consistency/README.md). This is a throwaway SQL prototype of the approval transaction, run on PostgreSQL 16; it is not a migration.

**Decision identifiers:**
- `ADR-nnn`: architecture decision records.
- `AD-nn`: decisions that need owner approval (listed in the [completion report](phase-3-completion-report.md)).

Phase 1 identifiers (`BR-`, `US-`, `D-`) and Phase 2 identifiers (`DD-`, `SCR`/screen IDs, `CMP-`) are referenced unchanged.
