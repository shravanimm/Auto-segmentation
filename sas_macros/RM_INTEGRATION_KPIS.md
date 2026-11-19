# RM integration for RCA - KPI calculation code and monitoring plan

Goal (manager): map KPI calculation code to NEW RCA KPIs in SAS Risk Modeling, then create a model
evaluation plan that uses them. Risk Modeling runs each KPI's **Code** tab and stores the value it
inserts as `(KPI_ID, KPI_VALUE)`; the segmentation module is called from that code, loosely coupled.

## 1. The five KPIs

All are "lower values = healthier". Only statistically significant segments count (multiple-testing
corrected). Thresholds below are PROPOSALS that need business sign-off, except PSI (industry
convention 0.10 / 0.25).

| KPI ID (exactly this text) | KPI name | Category | Value | Good | Warning | Critical |
|---|---|---|---|---|---|---|
| `rca_max_gini_drop` | RCA - Max segment Gini drop | Model performance | largest `Dev_Gini - Mon_Gini` over significant segments (0 if none) | < 0.05 | 0.05 to < 0.10 | >= 0.10 |
| `rca_max_ks_drop` | RCA - Max segment KS drop | Model performance | largest `Dev_KS - Mon_KS` | < 0.05 | 0.05 to < 0.10 | >= 0.10 |
| `rca_max_badrate_rise` | RCA - Max segment bad-rate rise | Model calibration | largest `Mon_BR - Dev_BR` (0.05 = 5 points) | < 0.05 | 0.05 to < 0.10 | >= 0.10 |
| `rca_max_segment_psi` | RCA - Max segment population shift (PSI) | Model stability | largest segment-size PSI | < 0.10 | 0.10 to < 0.25 | >= 0.25 |
| `rca_n_deteriorating` | RCA - Number of deteriorating segments | Model performance | count of significant segments whose Gini fell | 0 | 1 to < 3 | >= 3 |

### 1b. Impact KPIs from the module's derived scores (SIS, DIS, ...)

Same rules (lower = healthier, significant segments only, `kpi_id` = `metric`). These use the RAW scores,
which have the same meaning in every run. **Thresholds are not set yet**: the values are on a small
0-1 scale that depends on the portfolio, so calibrate them from the first real runs (rm_kpi_local_test.sas
prints the values) and have them signed off.

| KPI ID | Value | Category |
|---|---|---|
| `rca_max_sis` | largest `SIS_Raw` = AUC drop x exposure x population share x confidence | Model performance |
| `rca_max_dis` | largest `DIS_Raw` = population shift x AUC drop x exposure x (1 + mean feature PSI) | Model stability |
| `rca_max_business_impact` | largest `Business_Impact_Score` = population x exposure x (1 + PSI + Gini drop) | Model performance |
| `rca_max_portfolio_impact` | largest `Portfolio_Impact_Score` = population share x abs(Gini change) | Model performance |
| `rca_n_significant` | number of statistically significant segments | Model stability |
| `rca_max_feature_drift` | largest `mean_feature_psi` (average feature drift inside a segment) | Model stability |
| `rca_max_shap_shift` | largest `mean_shap_shift` (needs SHAP columns in the scored data) | Model stability |
| `rca_max_exposure_drift` | largest abs(`Exposure_Drift`) (exposure share change) | Model stability |
| `rca_max_calibration_drift` | largest abs(`Calibration_Drift`) (actual/expected default ratio shift) | Model calibration |
| `rca_max_ece_rise` | largest `Delta_ECE` (Feature Binning only) | Model calibration |

`SIS_Raw`, `DIS_Raw` and `Business_Impact_Score` come from all five techniques including Feature Binning.
`Portfolio_Impact_Score`, `Calibration_Drift`, `mean_*` come from the other four, and `Delta_ECE` from
Feature Binning only; a column a technique does not produce is simply ignored. With the default call
(Drift Tree + Feature Binning) every KPI above has a value.

### 1c. Trend KPIs (a run per period)

`Trend_Impact_Score` (TIS), the forecast and the early warning only exist in a TREND run, so these KPIs
run the module once per period of the scored data set. They need `%let sg_rm_period_col = <column>;`
in the Code tab (a month / quarter column in the scored data set) and about 20 s per period.

| KPI ID | Value | Healthier |
|---|---|---|
| `rca_max_trend_impact` | largest `Trend_Impact_Score` (0.4 frequency + 0.3 recency + 0.3 consistency of a recurring segment) | lower |
| `rca_n_early_warning` | segments whose Root_Cause_Score line is projected to cross the alert level within the horizon | lower |
| `rca_max_trend_slope` | steepest rising `Trend_Slope` of the Root_Cause_Score (per period) | lower |
| `rca_min_months_to_breach` | fewest periods until a projected breach (the horizon, 6, when none is flagged) | **higher** |

Open: does the Risk Modeling scored data set hold several periods and a period column? If it holds a single
period only, the trend KPIs need the earlier periods from the reference table instead.

`Root_Cause_Score` and `Severity_Score` are NOT KPIs: it is min-max normalised inside every run, so it cannot be compared
between runs or periods.

## 2. KPI code mapping (what goes on each KPI's Code tab)

Each KPI's Code tab holds the SAME lines except the last call. `kpi_id` MUST equal the KPI ID on the
KPI's Details tab (the form pre-fills a number such as 10000 - overwrite it with our text ID if the
field is editable, otherwise use that number as `kpi_id`); `metric` says what to calculate and is
always one of the five IDs in the table. That pair is the mapping between the code and the KPI.

```sas
filename segmac filesrvc folderpath="/Public/autoseg/macros";          /* <-- folder with the macros */
%include segmac(seg_compile_viya.sas);
%include segmac(csb_rm_kpi_segmentation.sas);
%let sg_rm_ref_folder = /Users/sastest1/My Folder/autoseg/ref;          /* <-- SAS Content folder for the reference file */
%let sg_rm_bootstrap = Y;                                               /* optional: first run becomes the baseline */
%let sg_rm_exclude_cols = ;                                             /* optional */
%csb_rm_kpi_segmentation(kpi_id=rca_max_gini_drop, metric=rca_max_gini_drop);   /* <-- the only line that differs */
```

The adapter ([csb_rm_kpi_segmentation.sas](autoseg_ucmacros/csb_rm_kpi_segmentation.sas)) follows the
Risk Modeling guidelines: local macro variables, inserts into
`&m_output_cas_libref..&m_kpi_value_otpt_cas_tbl_nm`, sets `m_kpi_calc_success_flg` to Y or N.

How it gets its data:

| Needed | Taken from |
|---|---|
| Monitoring data (features, target, score) | the scored data set `&m_scored_ds_libref_kpi_calc..&m_scored_ds_nm_kpi_calc` |
| Target / score column names | `&m_act_result_col_name` / `&m_est_result_col_name` |
| Development data | a REFERENCE file `rcadev_<model id>.csv` in `&sg_rm_ref_folder` (or a data set in `&sg_rm_ref_libref`), saved by the adapter in the development run (`m_run_type_cd = DD`) and read in ongoing / backtesting runs. With `sg_rm_bootstrap=Y` and no reference yet, the first ongoing run becomes the baseline (KPI value 0) |
| Everything else (features, weight, SHAP, parameters) | auto-detected / global defaults of the module |

## 3. Test before pasting into Risk Modeling

Run [rm_kpi_local_test.sas](rm_kpi_local_test.sas) in SAS Studio. It fakes the `m_*` macro variables and
the scored data set with the demo data, runs a development call and then the five KPI calls and prints
the KPI output table (5 rows, success flag Y).

## 4. Steps in Risk Modeling (KPIs first, then the plan)

For EACH of the five KPIs: **Configuration > KPIs > New**
1. Details: KPI ID (table above), KPI name, KPI category.
2. Threshold: tick "Thresholds are applicable"; choose **Lower values** as better health; add three
   intervals (Good / Warning / Critical) with the numbers above.
3. Code: paste the code from section 2 with that KPI's `kpi_id`. Save.

Then the plan: **Configuration > Model Evaluation Plans > New**
1. ID `RCA_SEGMENT_MONITORING`, a name and description (binary-target models).
2. Add the five KPIs (add the model's usual KPIs too if the manager wants one combined plan).
3. Save, then assign the plan to a model.

Important (message in the screenshot): thresholds are copied into a plan when the KPI is linked. If
a threshold is changed later, associate the KPI with the plan again.

## 5. Open points to confirm

1. Where is the development data in Risk Modeling for an ongoing run? The design stores a reference
   table in a persistent library on the development (DD) run; if Risk Modeling already exposes the
   development scored data set (or one library holds it), the adapter should read that instead.
2. Which library/path: the SAS Content folder for the macros and a writable persistent library for
   the reference table (placeholders `/Public/autoseg/macros` and `RMREF` above).
3. Business sign-off of the proposed thresholds.
4. Run time: each KPI call runs the module once (about 20 seconds with Drift Tree + Feature
   Binning on 5,000 rows), so five KPIs = five runs. If Risk Modeling can run them in one job, only
   the first call needs to run the module and the others can read the saved result.
