/* patch_realism.sas
   Makes the synthetic RLA data behave like a real portfolio, and seeds what the DQ / DD / SEG use case needs.
   Manager-approved ("handle the 100% accuracy"). Run AFTER the load + patches (add_rk_and_valid_start,
   patch_age_gender, add_age_column, add_reject_flag) and BEFORE append_rla_to_all_application_dim.sas,
   so the shared table gets the new outcomes. Backup first: RETAIL_LOAN_APPLICATIONS_BKP4.

   What it changes, and why
   1. SEG   Rejection risk differs by segment (product_category, employment_status, channel): a different
            intercept per product and employment type, and bureau score matters more for DIGITAL.
   2. DD    Drift over time: from Jan 2025 on, bureau score falls (up to -50), incomes shrink (up to -15%),
            inquiries rise. Development period = up to 31Dec2024, monitoring period = 2025 onwards.
            credit_range is recomputed from the new bureau score so the two stay consistent.
   3. Noise The outcome is drawn from a probability (logistic score + unexplained noise), not a fixed rule,
            so a scorecard reaches a high but not perfect accuracy. The intercept is set so 15% of the
            development period is rejected; later months then reject more because of the drift.
   4. DQ    Missing values are added at known rates, one column above the 50% DQ threshold:
            inquiries_180_days 55%, liquid_assets 8%, employment_status 4%, monthly_allowance_income 3%,
            dependants 2%, bureau_score 1.5%.
   Columns changed: bureau_score, credit_range, income columns, inquiries, outcome_cd, application_status,
   reject_flg, plus the missing values above. Everything else is untouched. */

cas rl1;
caslib _all_ assign;

/* guard: this patch compounds if run twice, so stop if the table was already patched
   (a patched table has missing bureau scores, a clean one has none) */
proc sql noprint;
  select count(*) into :n_prior from bankcrfm.retail_loan_applications where missing(bureau_score);
quit;
%macro guard;
  %if &n_prior > 0 %then %do;
    %put ERROR: bureau_score already has &n_prior missing values, so patch_realism.sas was run before.;
    %put ERROR: Reload the table first (load script, add_rk_and_valid_start, patch_age_gender, add_age_column, add_reject_flag).;
    %abort cancel;
  %end;
%mend;
%guard;

/* 0. backup */
data CASUSER.RLA_BKP4;
  set bankcrfm.retail_loan_applications;
run;
proc casutil incaslib="CASUSER" outcaslib="BANKCRFM";
  droptable incaslib="BANKCRFM" casdata="RETAIL_LOAN_APPLICATIONS_BKP4" quiet;
  save casdata="RLA_BKP4" casout="RETAIL_LOAN_APPLICATIONS_BKP4" replace;
quit;

/* 1. drift + risk score (no intercept yet), in WORK so the random numbers are repeatable */
data work.rla;
  set bankcrfm.retail_loan_applications;
  if _n_ = 1 then call streaminit(20270);

  /* months after Dec 2024 (0 for the development period) */
  m = max(0, intck('month', '31DEC2024'd, datepart(application_dt)));

  /* DD: drift */
  if m > 0 then do;
    if not missing(bureau_score) then bureau_score = max(300, bureau_score - min(50, 3*m));
    f = 1 - min(0.15, 0.01*m);
    monthly_employment_income = round(monthly_employment_income * f);
    monthly_allowance_income  = round(monthly_allowance_income  * f);
    total_monthly_income      = round(total_monthly_income      * f);
    total_income_declared     = round(total_income_declared     * f);
    if rand('uniform') < min(0.5, 0.03*m) then do;
      inquiries_90_days  = inquiries_90_days  + 1;
      inquiries_180_days = inquiries_180_days + 1;
      inquiries_365_days = inquiries_365_days + 1;
    end;
  end;

  /* credit_range follows bureau_score */
  if      bureau_score < 650 then credit_range = 'HIGH_RISK';
  else if bureau_score < 700 then credit_range = 'SUBPRIME';
  else if bureau_score < 750 then credit_range = 'NEAR_PRIME';
  else                            credit_range = 'PRIME';

  /* SEG: segment-specific behaviour */
  bw = 0.9;                                  /* weight of bureau score */
  if channel = 'DIGITAL' then bw = 1.3;
  seg = 0;
  if product_category = 'UNSECURED' then seg = seg + 0.4;
  if product_category = 'MORTGAGE'  then seg = seg - 0.4;
  if employment_status = 'BUSINESS_OWNER' then seg = seg + 0.3;
  if employment_status = 'EMPLOYED'       then seg = seg - 0.2;

  dti = min(monthly_installment_total / total_monthly_income, 3);
  z = - bw*(bureau_score - 680)/100
      - 0.5*log(total_monthly_income/60000)
      + 0.8*(worst_delinquency_12m > 60)
      + 0.7*(defaults_count > 0)
      + 0.5*dti
      + 0.05*inquiries_90_days
      + seg
      + 1.5*rand('normal');                  /* unexplained noise */
  dev = (m = 0);
run;

/* 2. intercept: bisection so that 15% of the development period is rejected */
%let lo=-15; %let hi=15; %let mid=0;
%macro calib;
  %do i = 1 %to 30;
    %let mid = %sysevalf((&lo + &hi)/2);
    proc sql noprint;
      select mean(1/(1+exp(-(z + &mid)))) into :mr trimmed from work.rla where dev = 1;
    quit;
    %if %sysevalf(&mr > 0.15) %then %let hi = &mid; %else %let lo = &mid;
  %end;
%mend;
%calib;
%put NOTE: intercept = &mid;

/* 3. outcome + missing values */
data work.rla;
  set work.rla;
  p = 1/(1+exp(-(z + &mid)));
  if rand('uniform') < p then do;
    application_status = 'REJECTED';
  end;
  else do;
    u = rand('uniform');
    if      p < 0.05 then application_status = ifc(u < 0.85, 'APPROVED', ifc(u < 0.95, 'CONDITIONALLY_APPROVED', 'REFERRED'));
    else if p < 0.15 then application_status = ifc(u < 0.55, 'APPROVED', ifc(u < 0.80, 'CONDITIONALLY_APPROVED', 'REFERRED'));
    else                  application_status = ifc(u < 0.30, 'APPROVED', ifc(u < 0.65, 'CONDITIONALLY_APPROVED', 'REFERRED'));
  end;
  outcome_cd = application_status;
  reject_flg = (application_status = 'REJECTED');

  /* DQ: missing values at known rates (done after the outcome, so they do not change it) */
  if rand('uniform') < 0.55  then inquiries_180_days = .;
  if rand('uniform') < 0.08  then liquid_assets = .;
  if rand('uniform') < 0.04  then employment_status = '';
  if rand('uniform') < 0.03  then monthly_allowance_income = .;
  if rand('uniform') < 0.02  then dependants = .;
  if rand('uniform') < 0.015 then bureau_score = .;

  drop m f bw seg dti z dev p u;
run;

/* 4. checks before publishing */
proc freq data=work.rla;
  tables application_status / nocum;
run;

proc sql;
  title 'Rejected rate by half-year (drift should push it up after 2024)';
  select year(datepart(application_dt)) as yr, ceil(month(datepart(application_dt))/6) as half,
         count(*) as n, mean(reject_flg) format=percent8.1 as rej_rate,
         mean(bureau_score) format=6.1 as avg_bureau
  from work.rla group by 1,2 order by 1,2;
  title 'Rejected rate by product and employment (segments should differ)';
  select product_category, employment_status, count(*) as n, mean(reject_flg) format=percent8.1 as rej_rate
  from work.rla group by 1,2 order by 3 desc;
  title;
quit;

proc means data=work.rla n nmiss;
  var bureau_score liquid_assets monthly_allowance_income dependants inquiries_180_days;
run;

/* quick strength check: the "c" in the association table is the AUC, expect about 0.85 to 0.90 */
proc logistic data=work.rla;
  model reject_flg(event='1') = bureau_score total_monthly_income worst_delinquency_12m defaults_count;
run;

/* 5. publish over the live table (same name, so nothing downstream changes) */
data CASUSER.RETAIL_LOAN_APPLICATIONS;
  set work.rla;
run;
proc casutil incaslib="CASUSER" outcaslib="BANKCRFM";
  droptable incaslib="BANKCRFM" casdata="RETAIL_LOAN_APPLICATIONS" quiet;
  save casdata="RETAIL_LOAN_APPLICATIONS" casout="RETAIL_LOAN_APPLICATIONS" replace;
  promote casdata="RETAIL_LOAN_APPLICATIONS" casout="RETAIL_LOAN_APPLICATIONS";
quit;
