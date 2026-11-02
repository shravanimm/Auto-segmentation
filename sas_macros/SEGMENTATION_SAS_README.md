# Auto-Segmentation in SAS — handover & review guide

Python → SAS port of the five segmentation techniques plus their shared
evaluation/scoring engine. **Pure Base SAS (Compute server): no CAS, no
VDMML/Risk Modeling licence, no Python at run time.**

> **Status (2026-10-14): executed in SAS Viya Studio and validated against Python for three techniques.**
>
> | Technique | Result vs Python (5,000-row demo) |
> |---|---|
> | AutoSlicer | pool 80/80; all 40 metrics PASS; top-10 identical populations (1 display label differs: `33` vs `33.01`) |
> | Drift Tree | pool 4/4; all 40 metrics PASS; top-N identical incl. labels |
> | Gradient Boosting | pool 116/116; all 40 metrics PASS; top-10 identical incl. labels (114/116 pool labels exact) |
> | K-Means | runs; top segments close to Python (same families, k=8, similar counts) - statistical equivalence only |
> | Feature Binning | runs; top-20 identical to Python on all 20 ranks (label, population, Root_Cause_Score to 5e-6, `Significant` flag 20/20) despite the different bootstrap RNG |
>
> Bugs found and fixed during the first runs (all in the SAS, none in the algorithms):
> semicolons inside `%put` text; `*/` inside a comment; `PROC SQL INTO :var` truncating numbers to ~8
> digits (now `format=best32.`); SAS `RB4.` truncating instead of rounding to float32 (now `seg_f32`);
> `IFN()` evaluating both arguments (array subscript out of range) in Feature Binning.

## 1. How it is called (Cirrus-friendly, loosely coupled)

One entry macro, plain parameters in, plain tables out:

```sas
%let _autoseg_ucmacros = /path/to/sas_macros/autoseg_ucmacros;
%include "&_autoseg_ucmacros/seg_compile.sas";

%csb_segmentation_calc_wrapper(
    dev_dta=lib.dev, mon_dta=lib.mon,
    techniques=AUTOSLICER DRIFT_TREE GRADIENT_BOOSTING KMEANS FEATURE_BINNING,
    target_col=default_flag, score_col=pd_score, weight_col=ead,
    feature_cols=age region employment_type bureau_score dti utilization,
    numeric_cols=age bureau_score dti utilization, categorical_cols=region employment_type,
    shap_cols=shap_age ...,           /* optional */
    out_prefix=seg);
```

`sas_macros/seg_execute.sas` is the ready-to-run script (set 3 paths).
Parameters of each technique are prefixed `as_ dt_ gb_ km_ fb_` and default to
`models/config.py`. A technique that fails does **not** stop the others
(`seg_run_log`: OK / ERROR / NOT_RUN + seconds).

### Output tables (the contract for the UI)

| Table | Content |
|---|---|
| `<out>_<tech>_segments` | top-N, public column names (`Dev_Count … Root_Cause_Score`) |
| `<out>_<tech>_rules` | **exact** machine-readable rule rows (feature, ptype, lower, upper, value). Use these, not the display text |
| `<out>_<tech>_portfolio` | significant top-N by Portfolio_Impact_Score (not for Feature Binning) |
| `<out>_<tech>_feature_psi` | in-segment PSI per feature for the top-N |
| `<out>_<tech>_pool` | every evaluated candidate (parity / audit) |
| `<out>_<tech>_log` | thresholds, pool size, … |
| `<out>_cross_top10`, `<out>_combined` | cross-technique ranking (normalised Root_Cause_Score, `Discovered_By`) |
| `<out>_kmeans_centroids/_encoding/_k_diagnostics` | what a consumer needs to *apply* the clusters |
| `<out>_run_log` | per-technique status |

`<tech>` = `autoslicer drifttree gradboost kmeans featbin`.

## 2. Architecture

```
csb_segmentation_calc_wrapper
 ├─ seg_autoslicer_grid → seg_autoslicer → seg_as_predicates / seg_as_step (beam search)
 ├─ seg_drift_tree        ─┐
 ├─ seg_gradient_boosting ─┼─ seg_tree_matrix → seg_tree_presort → seg_tree_fit (CART) → seg_tree_rules
 ├─ seg_kmeans            ─┘   (+ seg_km_encode/fit/predict/metrics/select_k)
 └─ seg_feature_binning (+ seg_fb_strength/bins_num/bins_cat/membership/calib/bootstrap/score)
        all techniques share:  seg_prep → seg_membership → seg_candidate_filter →
        seg_evaluate_candidates (AUC/KS, PSI, bad rate, calibration, exposure,
        in-segment feature PSI, SHAP) → seg_score_candidates (BH, SIS/DIS, Root
        Cause Score) → seg_rank_dedup → seg_publish
 → seg_cross_technique
```
A technique only has to produce **candidate row membership**; everything else is
shared, exactly as in the Python (`core/`).

## 3. What was verified (Python mirrors of the SAS logic vs the real Python)

| Piece | Result on the 5,000-row demo data |
|---|---|
| AutoSlicer pool (depth 2/3/4, beam 10/15) | identical set **and order** (80 / 80 / 91 candidates) |
| AUC, Gini, bad-rate p, PSI, feature PSI, SHAP, BH, SIS/DIS/Root-Cause, Jaccard de-dup | ≤ 1e-16 (golden values are rounded to 4-6 dp) |
| CART splits (Drift Tree, K-Means rule tree, 20 boosted trees) | identical partition to scikit-learn |
| Drift Tree pool / Gradient Boosting pool (50 trees) | **4/4 and 116/116 identical rule text and order**, incl. first-seen de-dup |
| Feature Binning bins (all 6 features + the quantile-grouping path) | identical labels |
| K-Means CH / Davies-Bouldin / silhouette / ARI formulas | ≤ 3e-17 |
| Structure of every macro file (`%macro/%mend`, `%do/%end` balance) | OK |

## 4. Where SAS cannot equal Python bit-for-bit (by construction)

| Item | Why | Effect |
|---|---|---|
| **K-Means** clusters / chosen *k* | different random stream (sklearn k-means++ vs SAS `RAND`) | statistically equivalent; compare top segments, not identities |
| **Feature Binning** bootstrap p-values / CIs | numpy RNG vs SAS RAND; 50 draws → 0.04 resolution in both | `Significant` can flip for borderline bins |
| FB calibration intercept/slope | sklearn lbfgs (C=1e9, 200 iter) vs `PROC LOGISTIC` MLE | small differences; feeds no score |
| KS statistic | SAS uses the tie-aware KS; Python's depends on numpy's arbitrary tie order | ≤ 2.6e-3 on demo; **same pool and top-10** when Python is re-run with it |
| Score-shift KS p-value | asymptotic (Stephens) vs scipy exact | ≤ 0.019; **0 of 80 significance flags change** |
| Rounded rule labels | SAS `ROUND` vs Python on exact binary ties (33.005 → 33.01 vs 33) | display only; the parity checker also matches on row counts |
| Exact ties between *different* features in a tree split | sklearn picks via a random feature order | membership identical; rule text could differ |
| Top_SHAP_Feature / Top_SHAP_PSI | not ported (diagnostic only, feed no score) | columns absent |
| Outlier treatment (`OutlierConfig`) | default "none"; uncommitted in the repo | not ported |

## 5. Faithfully-ported quirks (Python behaviour you may want to change later)

Everything below is **reproduced on purpose** so parity tests stay meaningful.
Each is a candidate for a deliberate, documented fix:

1. Displayed rule text is rounded to 2 dp and is not the true cut (2 of 15 Drift-Tree leaves differ by 1 row on the demo). Always use `_rules`.
2. RCA name filter is an *unanchored substring* match (`months_on_book` is excluded). Switch: `rca_name_filter=N`.
3. Missing values are handled differently per technique (trees: median; AutoSlicer: excluded from numeric bins; Feature Binning: its own "is Missing" bin; K-Means: dev median).
4. Feature Binning scores its bootstrapped pool and the remainder **separately** (different normalisation) and ranks them together.
5. Feature Binning's `Calibration_Drift` (intercept shift) ≠ the other techniques' (A/E-ratio shift); its calibration regression uses the raw PD, not logit(PD).
6. Feature Binning has no event-count gate and its Root_Cause_Feature is the binned feature itself.
7. K-Means: monitoring data influences the choice of *k* (drift-aware); the rule is only a description — real membership is the nearest centre.
8. `evaluate_segment` debug prints are not ported.

## 6. Known limits

* Scale: membership is a candidates × rows join and K-Means holds the matrix in memory
  (error above 5e7 cells; Python switches to MiniBatch above 200k rows). For 1M-row data
  move `seg_membership` / `seg_km_fit` to CAS (`PROC KCLUS`) — the logic is unchanged.
* The Feature Binning bootstrap table is ~`n_iter × rows` per candidate (fine for the demo).
* Timing guide (5k rows): AutoSlicer ~1 min, Drift Tree seconds, Gradient Boosting 50 trees ~2-3 min,
  K-Means (k 8-12, n_init 10) several minutes, Feature Binning ~1 min.
* Not ported: per-technique head-to-head table (`Overall_Score_100`), executive-summary text, multi-period
  trend/forecast, LLM narrative (the latter should stay outside SAS).

## 7. How to test (tomorrow)

1. `python sas_macros/parity/export_golden.py` (already run; files are in `sas_macros/parity/golden/`).
2. Edit the three paths in `sas_macros/seg_execute.sas`, run section by section.
3. Section 2 prints a PASS/FAIL table per metric for AutoSlicer, Drift Tree, Gradient Boosting.
   Tolerances: 1e-6 tight, 1e-4 for columns the Python rounds, 5e-2 for KS-type columns.
4. Section 3: compare K-Means / Feature Binning tops with Python by eye.
5. First-run syntax/runtime errors are likely somewhere in ~5,000 lines of untested SAS; fix from the log.

## 8. Decisions that need the manager

* Port-faithfully vs fix the quirks in §5 (recommended: faithful first, then fix each behind a switch).
* Is statistical (not bit-exact) equivalence acceptable for K-Means and Feature Binning bootstrap?
* Cirrus contract: who owns the AutoSlicer grid search (SAS side, `as_*_list`) vs the caller; output library (WORK vs a persisted caller library).
