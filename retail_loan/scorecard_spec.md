# RLA user-defined scorecard: final bins and points

Target (event): `REJECT_FLG` = 1 (application REJECTED). Data set: `RLA_APPLICATION` (Dec 31, 2024 Full build, 4,717 records).
Higher points = safer. Total runs 265 to 850; suggested cut-off about 550 (tested on retail_loan_applications.csv).
Give every **None of These** row 0 points. First range bin uses `>=`, the rest use `>`, all end with `<=`.

## Range variables

| Variable | Bins (start to end) | Points |
|---|---|---|
| AGE | 18-25 / 25-35 / 35-45 / 45-60 / 60-70 | 25 / 30 / 35 / 40 / 35 |
| BUREAU_SCORE | 300-600 / 600-630 / 630-650 / 650-720 / 720-850 | 50 / 93 / 135 / 199 / 220 |
| INQUIRIES_90_DAYS | 0-2 / 2-5 / 5-10 | 40 / 33 / 25 |
| LIQUID_ASSETS | 50000-250000 / 250000-500000 / 500000-750000 / 750000-1000000 | 25 / 30 / 35 / 40 |
| MONTHLY_ALLOWANCE_INCOME | 0-1200 / 1200-2600 / 2600-4500 / 4500-50000 | 15 / 29 / 47 / 60 |
| TOTAL_MONTHLY_INCOME | 5000-10000 / 10000-15000 / 15000-20000 / 20000-30000 / 30000-50000 / 50000-100000 / 100000-150000 / 150000-250000 | 20 / 20 / 20 / 68 / 80 / 88 / 96 / 100 |

## Value variables (semicolon between values, text in double quotes)

| Variable | Value | Points |
|---|---|---|
| CREDIT_RANGE | "HIGH_RISK" / "SUBPRIME" / "NEAR_PRIME" / "PRIME" | 15 / 43 / 59 / 70 |
| DEFAULTS_COUNT | 0 / 2;3 | 110 / 20 |
| DEPENDANTS | 0;1 / 2 / 3;4 | 30 / 25 / 20 |
| EMPLOYMENT_STATUS | "EMPLOYED" / "SELF_EMPLOYED" / "BUSINESS_OWNER" | 30 / 30 / 30 |
| WORST_DELINQUENCY_12M | 0;60 / 90;120 | 110 / 20 |

Not used: GENDER, REQUESTED_TERM (not created), APPLICATION_STATUS (the outcome, leakage if used as an input),
constant columns (flags etc.), duplicate income columns.
