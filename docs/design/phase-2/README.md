# Aisellia — Phase 2 design specification

**Status:** Proposed — **pending owner approval**. Nothing in this folder is an approved design until the owner says so.
**Inputs:** [Phase 1 product specification](../../product/phase-1-product-specification.md) (decisions D-01–D-15 remain formally pending owner approval; Phase 2 follows them as the working baseline). The master engineering prompt and the Phase 0 audit exist only in the project conversation, not in this repository.
**Scope:** design documentation only. No Flutter code, dependencies, schemas or backend work.

| # | Deliverable | File |
|---|---|---|
| 1 | Design direction exploration (3 concepts + recommendation) | [01-design-directions.md](01-design-directions.md) |
| 2 | Visual identity and design tokens | [02-visual-identity-and-tokens.md](02-visual-identity-and-tokens.md), [tokens/aisellia-tokens.json](tokens/aisellia-tokens.json) |
| 3 | Information architecture | [03-information-architecture.md](03-information-architecture.md) |
| 4 | Screen-by-screen specifications | [04-screen-specifications.md](04-screen-specifications.md) |
| 5 | Component specification | [05-components.md](05-components.md) |
| 6 | Motion design specification | [06-motion.md](06-motion.md) |
| 7 | Localization and accessibility specification | [07-localization-and-accessibility.md](07-localization-and-accessibility.md) |
| 8 | Design acceptance checklist | [08-design-acceptance-checklist.md](08-design-acceptance-checklist.md) |
| 9 | Implementation handoff | [09-implementation-handoff.md](09-implementation-handoff.md) |
| 10 | Phase completion and GitHub report | [10-phase-2-report.md](10-phase-2-report.md) |

**Artifacts** (design references, not working software; all data is sample data):
- [artifacts/concept-board.html](artifacts/concept-board.html) and its rendered PNG: the three directions plus Ledger in Sorani RTL and dark
- [artifacts/type-specimen.html](artifacts/type-specimen.html) and its rendered PNG: the typography pairing in both scripts
- [tools/contrast_check.py](tools/contrast_check.py): validates every declared colour pair in the token file against WCAG 2.1

**Identifier conventions:**
- Screens `SCR-xx-nn`
- Components `CMP-…`
- Motion tokens `motion.*`
- Checklist items `DAC-nn`
- Design decisions awaiting approval `DD-nn`

Phase 1 identifiers (`BR-`, `US-`, `D-`) are referenced unchanged.
