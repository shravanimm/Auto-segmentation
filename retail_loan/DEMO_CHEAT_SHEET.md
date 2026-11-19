# RM-CRD demo cheat sheet (today, 3 to 4 pm)

Server: https://d125618.contour.rci1352a-m1.tsr-rci-ciaws.hpos.rnd.sas.com  (RM `/SASRiskCirrus/Solutions/RM/`, Model Manager `/SASModelManager/`, Intelligent Decisioning `/SASDecisionManager/`)

## Opening (1 min): the journey slide
"One scorecard, built in Risk Modeling, makes decisions in CRD, and the decisions come back to RM. Data is synthetic. Nothing is production."

## Demo (about 10 min)

| # | Where | Click | Say |
|---|---|---|---|
| 1 | RM > Models > `copy_new_test` > **Model Definition** | Scroll the scorecard | "Four inputs: age, bureau score, dependants, income. Points per answer, one total score. No code." |
| 2 | Same model > **Bins and Proportions** | Point to cutoff and the four tiles | "Score range 40 to 390. Accuracy 89.3%, F1 65.4%. With three variables it was 87.6% and 62.3%. Adding income made the model better." |
| 3 | Model Manager > **Models** | Find `copy_new_test--14` | "As soon as the scorecard is saved it appears here, version 1. Nothing to copy or code." |
| 4 | Intelligent Decisioning > `CRD Credit Application Flow_testing` > double-click **4.0 Credit Policy_INC** > double-click the **4.1 Application Scorecard_RM_int** node | Click **UseModel**, then the model node, then Input and Output Variables | "One switch, `useUDModel = 'Yes'`: use the RM model; otherwise the standard rules. Four inputs go in, the score comes out." |
| 5 | SAS Studio: query on `rm_mdl.CRD_INC1` (keep it open) | Run, show 4 rows | "Same 300 applications through the full flow. Higher income, more points." |
| 6 | (optional) Browser: `/subjectContacts/contacts?limit=100` | Open one record | "Each decision is saved with time, score and offer. That is what RM reads back." |

Rows to show in step 5:

| Application | Income | Income pts | Score | Decision |
|---|---|---|---|---|
| 127111 | 230,213 | 100 | 390 | Approved |
| 124788 | 44,960 | 30 | 290 | Rejected |
| 108155 | 12,731 | 10 | 100 | Rejected |
| 120506 | 8,344 | none | none | Stopped early (PQD003) |

## Numbers to remember
- 300 applications: **46 approved, 16 referred, 238 rejected**. 246 reached the scorecard, 54 stopped in data-quality checks.
- Income version vs three-variable version: **same decision on all 300**. Scores differ, outcomes do not.
- Model accuracy in RM: 87.63% to 89.26%.

## Say it honestly
- Say: "The score feeds the decision. The policy rules decide the outcome here, so adding income changed scores, not decisions. How much weight the model should carry is a question for you."
- Do NOT say: "income improved approvals", "production-ready", or anything about real portfolios (data is synthetic).
- The return path (decisions into RM monitoring) works for recording; the RM monitoring side is being built.

## Likely questions
- **How does a model get from RM to CRD?** Saved in RM, it appears in Model Manager; the CRD model node picks it.
- **What triggers registration?** Automatic when saved (we saw it appear). Ask Sumedha if they want the exact trigger.
- **Does CRD store decisions?** No. We save each decision with a Record contacts node and read it back.
- **One at a time, so how does RM get many?** Records are read in a batch and flattened into one table.
- **What about performance (defaults)?** Not in this data; outcome-based monitoring needs a performance feed.
- **Rank-order warning in RM?** Simple model on synthetic data; focus is the integration.

## Pre-flight (do now)
1. Sign in to all three apps; open tabs in the demo order. Zoom 110%.
2. SAS Studio: have the `CRD_INC1` query ready (session `inc1` may be gone, so rerun the copy block first).
3. Do not click Create version, Publish, or Save on anything.
4. Open the demo flow ONLY through `Flow_testing`. Do not open `CRD Credit Application Flow_RM_int` or the original 4.0 (1.1) in front of anyone: the original 4.1 was edited on Nov 18 and still holds the new model, so that flow may show errors.
5. If asked about the 4.1 title: "This is the CRD 4.1 application scorecard step, with the model swapped to the new scorecard."
6. Fallback: if the test copy misbehaves, show the model in RM and Model Manager, and the saved test output, instead of the flow editor.

## After the demo (not today's demo, but do not forget)
- Restore the original 4.1 `RM_int (1.0)` to model `NewUDCRD--13` (3 inputs, outputs mapped as before), validate and save.
- Tell Sumedha in one line that you edited it by mistake and restored it.
- Check `Flow_RM_int` and the original 4.0 (1.1) have no red errors.
