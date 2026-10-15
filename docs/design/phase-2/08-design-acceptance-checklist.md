# 08 — Design acceptance checklist

**Phase 2, Deliverable 8** · Status: **Proposed — pending owner approval**

**When to use it:** for every Flutter screen or component implemented from Phase 4 onward, before it is called done. The checklist complements Phase 1's acceptance criteria (behaviour) with design acceptance (look, feel, accessibility and localization).

**How to use it:**
1. Copy §2 into the pull request (or the screen's review note).
2. Mark each item **Pass**, **Fail** or **N/A with reason**.
3. Attach the evidence listed in §3.

A screen with any **Fail** in the items marked ★ (business-critical) cannot be accepted.

---

## 1. Checklist items

### A. Purpose and hierarchy
| ID | Check | How to verify |
|---|---|---|
| DAC-01 | The screen's primary objective (from [04](04-screen-specifications.md)) is obvious within 3 seconds | First-glance review with a non-team person |
| DAC-02 | Exactly one primary action per surface; it is the most prominent element | Visual review |
| DAC-03 | Hierarchy comes from size and weight first; colour is not the only differentiator | Greyscale screenshot |
| DAC-04 | Business-critical data (product, quantity, price, total, customer, status) is readable without opening extra layers | Review against [04](04-screen-specifications.md) §5.3 |

### B. Tokens and consistency
| ID | Check | How to verify |
|---|---|---|
| DAC-05 | Only token colours, spacing, radii, elevations and type styles are used (no literals) | Code review / lint |
| DAC-06 | Uses existing components from [05](05-components.md); no near-duplicate card or row styles | Code review |
| DAC-07 | Spacing follows the scale and the section rhythm (24 between sections, 8 label → group) | Overlay check on a screenshot |
| DAC-08 | Matches sibling screens: same app-bar, row and sticky-bar patterns | Side-by-side screenshots |

### C. Typography
| ID | Check | How to verify |
|---|---|---|
| DAC-09 | Per-script styles applied (Sorani sizes and line heights in `ckb`) | Golden tests in both locales |
| DAC-10 | Numbers in compared columns use tabular figures and are end-aligned | Visual review |
| DAC-11 | Truncation rules respected; prices, totals, quantities, order numbers and buttons never truncated | 200% text-scale golden |

### D. States
| ID | Check | How to verify |
|---|---|---|
| DAC-12 | Loading, empty, error, success and offline states exist as specified, with the same visual language | State-by-state screenshots |
| DAC-13 ★ | No state shows success before the server confirms (saving, approval, status, sending) | Test with the network throttled or failing |
| DAC-14 | Errors preserve user input and offer Retry on the same surface | Forced-failure test |
| DAC-15 | Skeletons match content geometry and appear only after 300 ms | Throttled-network recording |

### E. Business correctness in the UI ★
| ID | Check | How to verify |
|---|---|---|
| DAC-16 ★ | Drafts and pending orders always show the pencil treatment and "Draft — not confirmed"; never approved-style colours | Visual review of every draft state |
| DAC-17 ★ | AI-filled values show provenance; inferred, conflict and missing states match [04 §5.2](04-screen-specifications.md#52-field-provenance-presentation-phase-1-86) | Review against fixtures |
| DAC-18 ★ | Approve is disabled while blocking issues exist, shows its reason, and requires the confirmation sheet | Interaction test |
| DAC-19 ★ | Message states use the exact wording from [05 CMP-MessageStateCaption](05-components.md#cmp-messagestatecaption); "Sent" never appears for messages Aisellia did not transmit | Review |
| DAC-20 ★ | Nothing claims a messaging channel is connected without a working integration; sandbox and test items are labelled | Review |
| DAC-21 ★ | Destructive actions follow the trigger → confirm → danger-button pattern with safe default focus | Interaction test |
| DAC-22 | Sample or demo data is labelled as such | Review |

### F. Navigation
| ID | Check | How to verify |
|---|---|---|
| DAC-23 | Back, edge-swipe and predictive back behave per [03 §3.1](03-information-architecture.md#31-stacks-and-back); tab stacks are preserved | Device test (Android and iOS) |
| DAC-24 | Correct surface type (full-screen, sheet, dialog, snackbar, banner) per [03 §3.3](03-information-architecture.md#33-modal-surfaces-which-one-to-use) | Review |
| DAC-25 | Unsaved-changes guard on dirty editors | Interaction test |

### G. Motion
| ID | Check | How to verify |
|---|---|---|
| DAC-26 | Animations use motion tokens; nothing perpetual except active progress | Code review |
| DAC-27 | Animations never block input; interrupting them leaves a correct, static state | Rapid-tap and navigation test |
| DAC-28 | Reduced-motion mode replaces spatial motion with crossfades or instant changes | Toggle test |
| DAC-29 | No dropped frames during the screen's transitions on the reference Android device (profile build) | Performance overlay recording |

### H. RTL and localization
| ID | Check | How to verify |
|---|---|---|
| DAC-30 | Layout mirrors per [07 §2.1](07-localization-and-accessibility.md#21-what-mirrors); non-mirroring items per §2.2 | `ckb` golden plus device |
| DAC-31 | Mixed-direction content (product names, phones, order numbers, prices) is isolated correctly | L10N-02, -04, -05 |
| DAC-32 | No hard-coded strings; pseudo-localized build shows no clipping | Pseudo-locale run |
| DAC-33 | Number, currency and date formatting follow [07 §3](07-localization-and-accessibility.md#3-numbers-currency-dates) and the digit setting | L10N-06, -07 |
| DAC-34 | Sorani strings reviewed by a native speaker | Reviewer sign-off |

### I. Accessibility
| ID | Check | How to verify |
|---|---|---|
| DAC-35 | Contrast of any new colour pair validated (added to the tokens and passing the script) | `contrast_check.py` |
| DAC-36 | Touch targets ≥ 48 dp | Tap-target test |
| DAC-37 | Screen-reader labels, roles, states and focus order correct; important changes announced | TalkBack and VoiceOver pass |
| DAC-38 | Usable at 200% text scale | Golden plus device |
| DAC-39 | No information conveyed by colour or stroke style alone | Greyscale review |

### J. Responsive
| ID | Check | How to verify |
|---|---|---|
| DAC-40 | Works at compact-small (320 wide) without horizontal scroll or overlap | Golden at 320×568 |
| DAC-41 | Medium and expanded layouts follow [02 §4.2](02-visual-identity-and-tokens.md#42-window-classes-and-adaptive-layouts) (rail, list–detail, max widths), not stretched phone layouts | Goldens at 768 and 1024 |
| DAC-42 | Safe areas and keyboard insets respected; the sticky bar is never covered | Device test |

### K. Performance and media
| ID | Check | How to verify |
|---|---|---|
| DAC-43 | Images decoded at display size; placeholders and broken states per [02 §7](02-visual-identity-and-tokens.md#7-photography-and-product-media) | Memory profile and visual |
| DAC-44 | Long lists virtualised; scrolling 500 items stays smooth | Profile build |

---

## 2. Copy-paste review template

```
Screen / component: ______  (ID: SCR-__-__ / CMP-____)
Reviewer: ______  Date: ______  Build/commit: ______
A Purpose      DAC-01 [ ] 02 [ ] 03 [ ] 04 [ ]
B Tokens       DAC-05 [ ] 06 [ ] 07 [ ] 08 [ ]
C Type         DAC-09 [ ] 10 [ ] 11 [ ]
D States       DAC-12 [ ] 13★[ ] 14 [ ] 15 [ ]
E Business ★   DAC-16 [ ] 17 [ ] 18 [ ] 19 [ ] 20 [ ] 21 [ ] 22 [ ]
F Navigation   DAC-23 [ ] 24 [ ] 25 [ ]
G Motion       DAC-26 [ ] 27 [ ] 28 [ ] 29 [ ]
H RTL/L10n     DAC-30 [ ] 31 [ ] 32 [ ] 33 [ ] 34 [ ]
I A11y         DAC-35 [ ] 36 [ ] 37 [ ] 38 [ ] 39 [ ]
J Responsive   DAC-40 [ ] 41 [ ] 42 [ ]
K Perf/media   DAC-43 [ ] 44 [ ]
Evidence links: goldens (en/ckb, light/dark, 1.0/2.0), device video, a11y notes
Result: ACCEPTED / CHANGES REQUIRED   Fails & reasons: ______
```

## 3. Required evidence per screen

1. Golden images: `en` and `ckb` × light and dark × text scale 1.0 and 2.0 (390×844), plus 320×568 and 1024×768 in `ckb`.
2. A short device recording of the main interaction on Android (and on iOS when available), including one forced failure.
3. Screen-reader notes (what was announced).
4. Contrast script output if any colour pair was added.
5. Native Sorani reviewer sign-off for new or changed strings.
