# Metrics Reference — Data Quality & Data Drift Macros

Exactly what each metric computes in this codebase — not the textbook-generic version, the actual formula implemented in `10_dq_macros.sas` / `20_drift_macros.sas`. Thresholds shown are the defaults; all are macro parameters and can be overridden at the `%main_wrapper` call.

---

## Data Quality (`10_dq_macros.sas`) — one dataset at a time

| Metric | Formula |
|---|---|
| Completeness % | `100 * (1 - missing_count / row_count)` |
| Uniqueness % | `100 * cardinality_count / (row_count - missing_count)` |
| Mean, Std Dev, Min, Max, Skewness, Kurtosis | Standard `PROC MEANS` output — no custom formula |
| Q25 / Median (Q50) / Q75 | `PROC MEANS` percentiles (25th / 50th / 75th) |
| Outlier count | Row is an outlier if value is outside `[Q25 − 1.5×IQR, Q75 + 1.5×IQR]`, where `IQR = Q75 − Q25` |
| Blocker: `high_missing` | Flag if `completeness_pct < missing_thresh` (default **50**) |
| Blocker: `zero_variance` | Flag if `cardinality_count ≤ 1` |
| Governance: `IDENTIFIER` | Flag if `uniqueness_pct ≥ id_uniqueness_thresh` (default **99.9**) **or** column name listed in `id_cols=` |
| Governance: `LEAKAGE` | Flag if numeric **and** `min ≥ 0` **and** `max ≤ 1` **and** `cardinality_count ≥ leakage_card_min` (default **50**) **and** not the target column |
| Governance: `PRIVACY` | Flag only if column name is listed in `private_cols=` — cannot be inferred from data alone |
| Column Health Score (0–100) | `100 × (0.35×completeness_score + 0.25×variance_score + 0.25×governance_score + 0.15×distribution_score)` — forced to **0** if blocked. Sub-scores: `completeness_score = completeness_pct/100`; `variance_score = 1 if cardinality>1 else 0`; `governance_score = 1 − 0.6×(any governance flag)`; `distribution_score = 1 if char OR \|skewness\|<1 else 0` |
| Dataset Readiness Score | Mean of all column Health Scores |

---

## Data Drift (`20_drift_macros.sas`) — dev vs. monitoring

| Metric | Formula |
|---|---|
| Schema Drift | Per column: `added` if only in mon, `dropped` if only in dev, `type_changed` if type/length differ, else `unchanged` — structural comparison, not a numeric formula |
| Completeness Drift | `delta_pp = mon_completeness_pct − dev_completeness_pct`. Pattern: `growing_missing` if `delta_pp ≤ −5`, `recovering` if `delta_pp ≥ +5`, else `stable_missing` (threshold = `delta_alert`, default **5**) |
| **CSI** (numeric PSI, per feature) | Build 10 deciles from **dev** data (`PROC RANK`). For each bucket *i*: `contrib_i = (mon_pct_i − dev_pct_i) × ln(mon_pct_i / dev_pct_i)`. `CSI = Σ contrib_i`. Label: `stable` if `<0.10`, `monitor` if `<0.25`, else `shift` |
| **Score-level PSI** (System Stability Index) | Identical formula to CSI, run once on `score_col` instead of a raw feature |
| Target/Event-Rate Drift | `delta_pp = mon_event_rate% − dev_event_rate%`, where `event_rate% = mean(target_col) × 100`. Label: `stable` if `\|delta_pp\|<3`, `notable` if `<8`, else `critical` |
| Cardinality Drift | `(mon_cardinality − dev_cardinality) / dev_cardinality` |
| Std Deviation Drift | `(mon_std − dev_std) / dev_std` |
| CV (Coefficient of Variation) | `CV = std / mean` (computed separately for dev and mon) |
| CV Drift | `(mon_cv − dev_cv) / dev_cv` |
| Kurtosis Drift | `mon_kurtosis − dev_kurtosis` (a plain difference, not a ratio) |
| Quantile Shift (median, in IQR units) | `(mon_median − dev_median) / (dev_Q75 − dev_Q25)` |
| Boundary Drift (min/max) | Reported as raw `dev_min/mon_min` and `dev_max/mon_max` side by side — no single combined number, read the two boundaries directly |
| Entropy Drift (categorical) | Shannon entropy `H = −Σ p_i × log2(p_i)` over each category's frequency share, computed separately for dev and mon. `entropy_delta = mon_entropy − dev_entropy` (no severity label — a raw diversity signal only) |
| **KS Statistic** (approximate, per feature) | Take dev's 5 checkpoints (min, Q1, median, Q3, max) with known dev-CDF values `(0, .25, .50, .75, 1.0)`. Linearly interpolate mon's CDF value at each of those same 5 x-positions using mon's own 5 known points. `KS = max` of the 5 absolute gaps between dev-CDF and interpolated mon-CDF. Label: `stable` if `<0.10`, `monitor` if `<0.20`, else `shift` |
| **Categorical PSI** (per categorical feature) | Same PSI formula as CSI, but buckets are the *actual category values* (via `PROC FREQ`, union of categories from both periods) instead of deciles. Same `stable` `<0.10` / `monitor` `<0.25` / `shift` thresholds |

---

## Why some metrics are "approximate" and one isn't

- **CSI, Score-PSI, Categorical PSI** are **exact** — built from real bin/category counts on the actual rows, not reconstructed from summary statistics.
- **KS Statistic** is **approximate** — it only checks 5 fixed quantile checkpoints, so a shift concentrated between two checkpoints can be missed (this is why KS and PSI occasionally disagree on the same feature — seen directly in the validation run against the synthetic drift dataset, where PSI caught `utilization`'s drift and KS did not).
