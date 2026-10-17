# H. Open validation gates, native review and sample collection

**Status:** Phase 8.5 is **provisionally accepted** by the owner, based on local test results. This page tracks what remains open and the procedures to close it. It is updated as each gate changes.

## 1. Gates

| # | Gate | State | Closes when |
|---|---|---|---|
| G1 | Real-model evaluation (24 scenarios, en / ckb / ar) | **Blocked: no dedicated staging API key** (re-checked when Phase 9 design started; still not set) | A dedicated staging key is configured ([A §2](a-key-configuration.md#2-how-to-configure-a-key-securely)), the plan and cost cap are shown to the owner and approved (§2), and the run is reported per language |
| G2 | Native-language review of the evaluation replies | **Open** | §3 completed for Sorani and Arabic |
| G3 | Non-numeric fabricated promises and claims (§4) | **Open, unsolved** | The rate measured in G1 is 0 for every language **and** the owner accepts the residual risk, or a second-pass check is added and evaluated |
| G4 | Hosted staging validation | **Blocked: no deployment authorization, no staging credentials** | The owner explicitly authorizes the deployment, then [D §4](d-staging-readiness.md#4-staging-checklist-for-when-deployment-is-authorized) passes |
| G5 | Consented conversation set | **Open: none collected** | §5 completed |
| G6 | AD-07 / AD-08 decisions and Console spend limit | **Open: owner decisions** | Recorded by the owner ([C](c-provider-data-and-cost.md)) |

**Rules for G1:**
- No paid call is made with the assistant's own session credentials or with another environment's credentials. The evaluation reads `ANTHROPIC_API_KEY` from the process environment only, and its base URL is pinned to `https://api.anthropic.com`.
- A key in the environment is not consent to spend. The plan is shown and the owner approves it before any paid call.

## 2. Evaluation procedure, once a key exists

1. **Check the key is the dedicated one.** It must belong to the staging workspace, and that workspace must have a spend limit. The owner confirms both; the assistant only checks that the variable is present and never prints it.
2. **Show the plan, at no cost.** Run `eval/run_eval.ts --plan` and send the owner:
   - the scenario count per language;
   - the model, effort and inference region;
   - the cap (`--max-cost-usd`, proposed USD 3) and the expected cost (about USD 0.5–1).
3. **Wait for the owner's explicit approval** of that plan.
4. **Run** with the approved cap, on the **local** stack. The script refuses any other database.
5. **Report per language** (en, ckb, ar):
   - pass rate;
   - grounded accuracy;
   - fabrication caught and fabrication shown;
   - escalation caught, missed and false alarms;
   - approvals, which must be 0;
   - latency p50 and p95;
   - cost.

   Failed scenarios are listed with their reasons. The report states plainly that **language quality is not measured by the script**.
6. **Hand the replies to native review** (§3). The report file stays in `eval/out/`, which git ignores.

## 3. Native-language review protocol

**Reviewers:**
- one native Sorani speaker from the Kurdistan Region;
- one native Arabic speaker familiar with Iraqi usage.

Neither may be the prompt author. Paid or volunteer; named by the owner.

**Material:** for every Sorani and Arabic result, and a sample of 5 English ones, the reviewer sees:
- the customer's messages;
- the suggested reply;
- the store facts used.

Model internals and pass / fail are hidden, so the reviewer is not anchored.

**Rubric** (each 1–4, plus a free comment):

| Criterion | 4 means | Blocking if |
|---|---|---|
| Correct language and script | Right language and dialect, Sorani in Arabic script with correct Kurdish letters (ڕ ڵ ۆ ێ ە) | Wrong language, or Latin-script Kurdish when the customer wrote in Arabic script |
| Natural and polite | Sounds like a courteous local shop | Rude, robotic or culturally inappropriate |
| Faithful | Says only what the facts and the conversation support | **Any promise, price, discount, confirmation or availability claim not in the facts: record it as a fabrication even if the checks passed** |
| Helpful | Answers the question or asks the right clarifying question | Ignores the question |
| Numbers, currency and names | Prices and currency rendered correctly in context | A wrong or garbled number |

**Also in scope:** the server's fixed phrases (holding reply, availability labels, currency labels) and the 156 Phase 8 app strings in Sorani.

**Outcome:**
- G2 passes when no reply has a blocking issue and the average of every criterion is at least 3 in each language.
- Fabrications found here count toward G3.
- Findings go into a review file **outside the repository**, because it quotes conversation text. A summary without quotes goes into this document.

## 4. Open risk: non-numeric fabricated promises (not solved)

**What is enforced:**
- Prices, fees, stock and delivery times reach the customer only as server-rendered facts.
- Model-written numbers must come from the catalog or the customer.
- A widened keyword guard runs in three languages.

**What is not:** promises, claims and free-delivery statements **without numbers or listed keywords still pass**. Probed and confirmed:
- "It reaches you the day after."
- "You will have it before the weekend."
- "Nothing to pay for delivery."
- "Your parcel is with the courier."

**Why it matters more in Phase 9:**
- Today a seller copies the text by hand.
- With a live channel the seller taps Send. Review still happens, but it becomes faster and easier to skip.

**Controls in the Phase 9 design** ([Phase 9 F](../../architecture/phase-9/f-seller-sending-workflow.md)):
- no automatic sending;
- the authorized text is exactly what is sent;
- AI-originated text is labelled in the composer;
- auto-send remains out of scope.

**Options to reduce it further, each needing evaluation with a key:**
1. a stricter prompt (p8.2) with explicit rules against time, delivery-cost and order-state statements;
2. a second, cheap classifier call that labels each reply segment as a promise, claim or offer;
3. limiting AI replies to fixed, server-rendered sentence frames for delivery and order-status topics.

**This risk must not be reported as solved** until G1 and G2 show no such fabrication and the owner accepts the result.

## 5. Consented conversation collection

The collection template, consent texts (en / ckb / ar, with native review required), consent register and file format are in [F](f-consented-samples.md).

| Step | Owner | State |
|---|---|---|
| Native review of the consent texts | Owner and reviewers | Open |
| Pilot sellers recruited to collect | Owner | Open |
| At least 30 Sorani, 15 Arabic and 10 English consented, anonymised conversations, stored outside the repository | Pilot sellers and owner | **0 collected** |
| Consent register kept separately | Owner | Open |
| Evaluation on the set (`--set=/outside/repo/file.json`) after G1's procedure | Assistant, after approval | Not started |

No consented conversation will be invented, reconstructed or paraphrased into a "realistic" sample.
