# CRD decision flow: where the output is stored and what it contains

Action item 1 (manager): identify where the CRD output is stored and understand the output data.
Status: DRAFT. Items marked TODO need the `proc contents` listing of the output table (see the end).

## 1. Where the output lives

| Item | Value |
|---|---|
| Decision flow | `CRD Credit Application Flow_RM_int` (v1.0), built on the CRD 2026.11 content |
| How it was run | SAS Intelligent Decisioning > Scoring test (Test7 on `RLA_CRD_FULL3`, later runs on `RLA_CRD_FULL4`) |
| Input table | `rm_mdl.RLA_CRD_FULL3` / `RLA_CRD_FULL4` (one row per application, 10 JSON grid columns plus scalar columns) |
| Output table | CAS library `rm_mdl`, named `<test name>_<flow name>_<timestamp>_output` (about 100 characters) |
| Example | `CRD Credit Application Flow_RM_int_Test7_CRD Credit Application Flow_RM_int_2026-11-15_11-28-50_output` |
| Granularity | One row per input application |
| Also stored | Log and Code files (`/files/files/...`, see the test's Output Data page), Rule-Fired Analysis and Decision Path Tracking (only when rule-fired tracking is ticked on the test) |
| Not stored | Nothing is written to Cirrus. `crd_preset_viyabaseurl` is blank, so every REST call returns `HTTP status= 0` and the test shows "Completed with errors". This is expected and harmless. |

Reading the long table name in SAS: copy it to a short name first.

```sas
proc cas;
  table.copyTable /
    table={caslib="rm_mdl", name="<output table name>"},
    casout={caslib="rm_mdl", name="CRD_T7", replace=true};
quit;
```

## 2. How a decision is produced

Stages, in order: Intake > Data quality > Eligibility > Credit policy (4.1) > Application scorecard (4.1 RM_int: RM model `NewUDCRD--13` when `useUDModel='Yes'`, else the standard 4.2.x rule sets) > Risk segment > Affordability (5.1) > Pricing (6.1).

Each stage adds one or more reason rows (`Rule_Level` = `crd_CAPPROVED`, `crd_REFER` or `crd_REJECT`). The final `ApplicationCurrentStatus` is the most severe one: any reject wins, then refer, then approve.

## 3. Key output columns (confirmed from logs and test output)

| Column | Meaning |
|---|---|
| `ApplicationCurrentStatus` | Final decision: `crd_CAPPROVED`, `crd_REFER` or `crd_REJECT` |
| `ErrorCode`, `ErrorDescription` | Set only when a data-quality or eligibility check stops the application early (for example `PQD015`, worst delinquency in 12 months over policy). Blank for normal decisions. |
| `DecisionStatus` | Blank in our tests |
| decision reason codes (JSON) | One row per fired rule: rule name, description, reason code, level, id. Examples: `CPR002` (4.1.7, high 90-day inquiries, refer), `AFD002` (5.1.2, high unsecured exposure, reject), `PRC002` (6.1.2, approved rate), `CPD003` (4.1.3, bureau score) |
| `_ApprovedAmount`, `_ApprovedRate` | Offer from Pricing. Note: also filled for rejected applications because Pricing always runs. Read the status first. |
| `_RiskSegment` | `crd_VL`, `crd_LO`, `crd_ME`, `crd_HI`, `crd_VH`. Blank when the application stopped before scoring (for example `PQD015`). |
| `_IncomeSegment` | Income band. `crd_HIGH` for all current test rows. |
| `AppScoreCard_Score` | Application scorecard output (RM model score when `useUDModel='Yes'`) |
| `_PrimaryApplicantBureauScore`, `_TotalIncomePrimaryApplicant` and other `_Primary*` | Intake-derived values for the primary applicant |
| `PathID` | Decision path taken |
| `*_Checklist_Output` grids | Per-stage checklist results |
| input grid columns | The ten input JSON grids are carried through unchanged |
| `Rules Fired Count` | 0 unless rule-fired tracking was ticked on the test |

The output has no `ApplicationID` column. Join back to the input with `ApplicantID` (the primary applicant id, e.g. `1383190001`; the application id is that value without the last 4 digits) or `_PrimaryApplicantID`.

### Full column groups in the output table (confirmed from the Test9 column listing)

| Group | Columns |
|---|---|
| Decision | `ApplicationCurrentStatus`, `DecisionStatus`, `ErrorCode`, `ErrorDescription`, `ReasonCD`, `decisionReasonCodes` (JSON: rule, description, reason code, level, id), `PathID`, `ruleFiredFlags`, `rulesFiredForRecordCount`, `DecisionFlowName`, `DecisionFlowStep`, `DecisionFlowVersion` |
| Offer (pricing) | `_ApprovedAmount`, `_ApprovedRate`, `_ApprovedTerm`, `_ApprovedLTV`, `_RequestedMonthlyInstallment` |
| Segments | `_RiskSegment`, `_IncomeSegment`, `_CustomerFlag`, `_ApplicantType` |
| Affordability | `_DebtToIncomeRatio`, `_DispNetIncPrimaryApplicant`, `_UnsecuredExposure`, `_AllowedUnsecuredExposure`, `_MaxDebtToIncomeRatio`, `_MaxIncomeMultiplier` |
| Policy limits | `_Policy_MinimumAge` (18), `_Policy_MaximumAge` (75), `_Policy_MinimumIncomeAmount` (1500) |
| Primary applicant (derived at Intake) | `_PrimaryApplicantID`, `_AgePrimaryApplicant`, `_PrimaryApplicantBureauScore`, `_PrimaryApplicantDependents`, `_PrimaryApplicantEducation`, `_PrimaryApplicantEmpType`, `_PrimaryApplicantEmplmntDurMths`, `_PrimaryApplicantMarStatus`, `_PrimaryApplicantResStatus`, `_PrimaryApplicantAvgDebitAmt`, `_PrimaryApplicantAvgDepositAmt`, `_TotalIncomePrimaryApplicant`, `_TotalExpensesPrimaryApplicant`, `_TotalAssetsPrimaryApplicant`, `_TotalLiabsPrimaryApplicant` |
| Credit history | `_DelinquencyStatus` (current), `_WorstDelinquency12Mths`, `_BureauTotalLiabilityBalance`, `_BureauUnsecuredBalanceAmount`, `_PrimApplicantBureauTotInstAmt`, `_TotalLiabilityBalance` |
| Application scorecard components | `AppScoreCard_Score_Age`, `_Assets`, `_Dependts`, `_Education`, `_Empl`, `_EmplStatus`, `_MaritalStatus`, `_ResStatus`, `_WDelStat12m`. These are blank when the RM-model branch (`useUDModel='Yes'`) is used. |
| Cirrus payloads (not sent) | `crd_cre_*_json_body`, `crd_cre_*_respBody`, `crd_pat_cra_*`, `_linktype_*`, `crd_preset_*`. These hold the JSON the flow would post to Cirrus. The response bodies are blank because no URL is set. |
| Input echo | The ten `*DataGrid` columns, plus `ApplicantID`, `ProductCode`, `SimulationFlag` |

## 4. Outcomes in the 20-row test

Input `rm_mdl.RLA_CRD_FULL5`, Test9 (Nov 15, 2026). Source `worst_delinquency_12m` is in days (0/60/90/120); it is converted to a status (0, 2, 3, 4), and the current delinquency status is set to 0.

| Status | Rows |
|---|---|
| `crd_CAPPROVED` | 11 (55%) |
| `crd_REFER` | 2 (10%) |
| `crd_REJECT` by affordability `AFD002` (income 55k to 82k against 1.2M to 1.9M requested) | 4 |
| `crd_REJECT`, no bureau score (score 0, risk segment `crd_HI`) | 1 |
| `crd_REJECT` `PQD015` (120-day delinquency) | 2 (no risk segment, no offer) |

Earlier iterations (kept for the audit trail): Test7 had 4 `PQD015` rejects because days were read as a status; Test8 had 4 `PQD014` rejects because the current delinquency status was set from the 12-month history.

Observations:
- Risk segment is `crd_LO` for 17 of 20, including bureau scores from 662 to 847, and income segment is `crd_HIGH` for all 20, so the two segmentations show little spread. To investigate: the "Temporary hard-code output" node in CRD 4.0 and the segmentation tree cut-offs.
- The "high inquiries 90d" refer rule (`CPR002`) fires on the referred applications.

### 300-row test (Test16, input `rm_mdl.RLA_CRD_T300`, built by `build_crd_test_table.sas` v2.3)

Sample: 300 applications, stratified by product category, with incomes scaled into the flow's segment range, requested amount tied to income and term, product by income band, half the rows with a CustomerID.

| Status | Rows |
|---|---|
| `crd_CAPPROVED` | 54 (18%) |
| `crd_REFER` | 31 (10%) |
| `crd_REJECT`, no error code | 149 (50%) |
| `crd_REJECT` with error code (`PQD010` 27, `PQD007` 20, `PQD015` 18, `PQD003` 1) | 66 (22%) |

Rule firings (rows): `AFD001` disposable income 116, `AFD002` unsecured exposure 69, `AFD003` 21, `CPD001` 15, `CPD003` 12 (rejects); `CPR002` high 90-day inquiries 76 (refer).
Segments: income HIGH 255, MED 25, LOW 20; risk segment for customer flag Y: LO 113, ME 6, HI 1; for customer flag N: all scored rows `crd_VH`.

Findings:
1. **Existing-customer risk segment (CustomerFlag = N):** the tree reads `ApplicationScore` against probability cut-offs (0.026 to 0.032), but the RM model returns points (about 40 to 290), so every scored row lands in `crd_VH`. Options: change the cut-offs in a new version of CRD Risk Segment, or convert points to a PD before the tree. For Sumedha to decide.
2. **Customers without CustomerID (flag Y):** the tree uses BehaviourScore, which the "Temporary hard-code" node sets to 200, so the segment depends on bureau score only (LO for 562 and above).
3. `PQD010` / `PQD007` (age and income minimums by product) come from the lookup tables `CRD Policy - Minimum Age by Product` and `Minimum Monthly Income by Product` (v1.3). The test data's product mapping is a placeholder (by income band).
4. `AFD001` (disposable income) is the largest single reject reason (116 rows); its formula has not been reviewed yet.

## 5. Known issues to raise with Sumedha

1. Rule 4.1.3 was inverted (rejected when bureau score > 500). Fixed in our copy only: rule set 1.1, treatment 1.1, group 1.3 (activated). Originals untouched.
2. Rule 4.1.6 compares `_RiskSegment eq 'VH'` against `crd_VH`, and the input is varchar(2), so it never matches.
3. The pricing tree uses `VL`/`LO`/etc. but the risk tree returns `crd_VL`/`crd_LO`/etc.
4. `worst_delinquency_12m` is in days in the source but eligibility 3.1.8 expects a status (0 to 3).
5. `_ApprovedAmount`/`_ApprovedRate` are populated on rejects.
6. Group 1.3 is now active for everyone using the shared environment.
7. Do not set `crd_preset_viyabaseurl` to a real URL without her permission.

## 6. To complete this document

Run this and paste the Variables table here to fill section 3 exactly:

```sas
proc contents data=rm_mdl.CRD_T7 order=varnum;
  ods select Variables;
run;
```

## 7. Gap analysis: CRD output vs RLA (RM closed-loop view)

Compared: Test23 output (300 rows) against `rm_mdl.RLA_APPLICATION`. The test input `rm_mdl.RLA_CRD_T300D` is built from RLA with the **original, unscaled values** and the **real keys**. Programs: `fix_rla_real_keys.sas`, `promote_rla_original.sas`, `build_crd_test_table_v3.sas`, `compare_crd_output_vs_rla.sas`. Dates: 17 Nov 2026.

### 7.1 Changes made to RLA

`rm_mdl.RLA_APPLICATION` (the original, promoted) now has 108 columns: the 103 original plus `application_ts`, `valid_start_dt`, `customer_rk`, `applicant_rk`, `customer_key`. Backups: `RLA_APPLICATION_BKP_20261117` (original) and `RLA_APPLICATION_BKP2_20261117` (first keys).

Keys come from the source `BANKCRFM.RETAIL_LOAN_APPLICATIONS`: `customer_rk` = `customer_id` (= application_id + 100000), `applicant_rk` = `applicant_id` (= application_id + 200000). The same `customer_id` was put into `ALL_APPLICATION_DIM` as `CUSTOMER_RK` by `append_rla_to_all_application_dim.sas`. The RM build output had `CUSTOMER_ID` blank on all 4,720 rows although the source has it on all 50,000, so the RM project's variable mapping for `CUSTOMER_ID` should be checked. Every applicant has been a customer for 6.5 to 7 years and `vip_flag` is N for all, so RLA has no new customers.

Risk: `rm_mdl.RLA_APPLICATION` is an RM build output. A rebuild may drop the five added columns. To keep them, add them to the source table and as variables in the RM project.

### 7.2 Keys and time

| RM key | RLA | CRD output | Status |
|---|---|---|---|
| Application | `application_rk` | `ApplicationID` (text) | Joins, 300 of 300 |
| Applicant | `applicant_rk` | `ApplicantID` | Equal on 300 of 300 |
| Customer | `customer_rk` | `CustomerID` | Filled, equals `customer_rk` |
| Application date | `application_dt` | `ApplicationDate` (text, date only) | Present |
| Scoring date and time | none | `ApplicationTimestamp` | Stamped by the flow at run time (UTC) |
| RLA application datetime | `valid_start_dt` | `RequestTimestamp` | Carried through from the test table (`application_ts`) |

Flow variables with **Output** ticked: `ApplicationID`, `ApplicationDate`, `CustomerID`, `ApplicationTimestamp`, `RequestTimestamp`, `ApplicationScore`.

### 7.3 Values

| Field | Result (300 rows) |
|---|---|
| Age | 300 agree |
| Bureau score | 297 agree. 3 rows have no bureau score in RLA; the test table sets them to 0 (no scorecard effect: missing and 0 both score 0 points). |
| Dependants | 292 agree. 8 rows have no dependants value in RLA; the test table sets them to 0, which gives them 10 scorecard points instead of the 5 a missing value would get. |
| Income | ratio CRD / RLA = 1.0 on every row (amounts unscaled) |

### 7.4 Outcome: RLA history vs CRD decision (Test23)

| RLA outcome | CRD approved | CRD refer | CRD reject |
|---|---|---|---|
| APPROVED (181) | 33 | 13 | 135 |
| CONDITIONALLY_APPROVED (45) | 6 | 0 | 39 |
| REFERRED (29) | 3 | 3 | 23 |
| REJECTED (45) | 4 | 0 | 41 |

Exact agreement 83 of 300 (28%). The flow rejects 41 of 45 historical rejections (91%) and approves 39 of 226 historical approvals (17%), referring 13 and rejecting 174. RLA outcomes are synthetic, not from a real decision process, so this is a difference between the flow and the generated history, not proof that either is wrong.

Test23 totals: 46 approved, 16 refer, 238 reject. 246 rows reach the scorecard; 54 stop early: `PQD003` 38 (monthly payment above monthly income, real data) and `PQD015` 16 (worst 12-month delinquency over policy, real data).

### 7.5 Remaining gaps and notes

1. No model name or version in the output.
2. `CreditRange` is not mapped as an input, so it is not in the output (RLA has `credit_range`).
3. `ApplicationScore` is filled on 246 of 300 rows; the other 54 stop at a data-quality check and have no score or risk segment.
4. All applicants are existing customers (flag N), and the risk tree returns `crd_VH` for every scored row (points compared against probability cut-offs). Question for Sumedha.
5. Product code is a placeholder by income band (293 of 300 rows `crd_PLATINUM`). The mapping from RLA `product_category` and `product_code` to CRD products needs Sumedha.
6. RLA outcomes are application decisions, not loan performance. A closed loop that monitors defaults needs a performance field, which RLA does not have.
7. Code mapping for the export: `APPROVED`/`CONDITIONALLY_APPROVED` to `crd_CAPPROVED`, `REFERRED` to `crd_REFER`, `REJECTED` to `crd_REJECT` (RM codes `ACC`/`CAP`, `REF`, `REJ`).
8. Test-data lesson: dates before 1960 are negative SAS datetimes. The first builder turned dates of birth before 1960 into stars, which the flow read as a missing age and rejected with `PQD010` (24 of 300 rows in Test21). Fixed in `build_crd_test_table_v3.sas`; earlier tests (Test16 and before) were affected too.
