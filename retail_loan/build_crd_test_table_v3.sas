/* build_crd_test_table_v3.sas
   Builds the CRD decision-flow test table from rm_mdl.RLA_APPLICATION (the updated one with the real keys).
   Output: rm_mdl.&outname (default RLA_CRD_T300D): one row per application, 10 JSON grids + scalar columns.

   Changes from v2:
   - Keys are the real RLA keys: ApplicantID = APPLICANT_RK (also inside every grid), CustomerID = CUSTOMER_RK
     on EVERY row (RLA has no new customers, so every row takes the existing-customer path).
   - Money amounts keep their ORIGINAL RLA values (scaled=0). Set scaled=1 to get the old income spread back.
   - RequestedAmount etc. are the original RLA requested_* values when scaled=0.
   - ApplicationTimestamp / RequestTimestamp = RLA application_ts (the flow overwrites ApplicationTimestamp with the
     scoring time; RequestTimestamp passes through).
   - sc_* columns for the standalone "CRD - 4.1 - Application Scorecard_RM_int" test (map them by hand there).
   - N >= number of RLA rows means "take all rows" (no sampling).
   TEMPORARY placeholders (unchanged): ProductCode by income band, employment status crd_EMPLOYED. */

%let N        = 300;              /* 300 = sample; 4720 = all RLA rows */
%let seed     = 20261116;
%let scaled   = 0;                /* 0 = original RLA amounts, 1 = old income spread */
%let outname  = RLA_CRD_T300D;

/* fresh, named CAS session */
cas bld4;
libname rm_mdl clear;
libname rm_mdl cas caslib="rm_mdl" sessref=bld4;

/* quick check: must print 3 rows and the new key columns */
proc print data=rm_mdl.RLA_APPLICATION(obs=3); var application_rk applicant_rk customer_rk application_ts; run;

/* 1. sample (or all rows) --------------------------------------------------------- */
data work.src;
  set rm_mdl.RLA_APPLICATION;
run;
proc sort data=work.src; by product_category; run;

proc sql noprint; select count(*) into :nsrc trimmed from work.src; quit;

%macro pick;
  %if &N >= &nsrc %then %do;
    data work.samp; set work.src; run;
  %end;
  %else %do;
    proc surveyselect data=work.src out=work.samp method=srs n=&N seed=&seed;
      strata product_category / alloc=proportional;
    run;
  %end;
%mend;
%pick;

/* 2. build scalar columns and the ten grids -------------------------------------- */
data work.crd;
  set work.samp;
  if _n_ = 1 then call streaminit(&seed);

  length g $1000 pid $20 dob empstart appdate $10
         applicantDataGrid individualDataGrid incomeDataGrid expenditureDataGrid
         creditBureauDataGrid existingAccountDataGrid existingAccountDetailsDataGrid
         employmentDataGrid assetDataGrid liabilityDataGrid $4000
         ApplicationID $12 ApplicationDate $10 ApplicantID $20
         ApplicationCurrentStatus $30 ProductCode $20 SimulationFlag $1
         crd_preset_viyabaseurl $200 useUDModel $3 RequestFrom $20
         CustomerID $20 RequestedCurrency $3
         ApplicationTimestamp RequestTimestamp $19;

  %if &scaled = 1 %then %do;
    u = rand('uniform');
    if      u < 0.12 then f = 0.02;
    else if u < 0.23 then f = 0.04;
    else if u < 0.35 then f = 0.07;
    else if u < 0.60 then f = 0.12;
    else if u < 0.85 then f = 0.30;
    else                  f = 0.60;
  %end;
  %else %do;
    f = 1;
  %end;

  inc0    = coalesce(total_monthly_income, monthly_employment_income, 0);
  exp0    = coalesce(total_monthly_expenses, 0.35 * inc0);
  income  = round(inc0 * f);
  expense = round(exp0 * f);
  assets  = round(coalesce(liquid_assets, 0) * f);
  liab    = round(coalesce(liability_amount, 0) * f);
  bal     = round(coalesce(bureau_total_liab_balance, 0) * f);
  inst    = round(coalesce(monthly_installment_total, 0) * f);
  unsec   = round(coalesce(unsecured_balance, 0) * f);
  defamt  = round(coalesce(default_amount, 0) * f);
  delamt  = round(coalesce(delinquent_amount, 0) * f);
  pubamt  = round(coalesce(bureau_public_record_amount, 0) * f);

  bscore  = coalesce(bureau_score, 0);
  dep     = coalesce(dependants, 0);
  wd      = ceil(coalesce(worst_delinquency_12m, 0) / 30);   /* days -> status */

  aid      = application_rk;
  pid      = strip(put(applicant_rk, 15.));                  /* the REAL applicant key */
  /* test the source value BEFORE converting: put(., yymmdd10.) gives blanks plus a dot, not '.'.
     Datetimes are seconds since 1960 and are NEGATIVE before 1960 (born in 1959 = about -3.5e8),
     so decide datetime vs date by the SIZE of the value (abs > 1e6), not by its sign. */
  if not missing(date_of_birth) then
    dob = put(ifn(abs(date_of_birth) > 1e6, datepart(date_of_birth), date_of_birth), yymmdd10.);
  else dob = put(intnx('year', today(), -coalesce(age, 40), 's'), yymmdd10.);   /* no DOB: derive from AGE */
  if not missing(employment_start_date) then
    empstart = put(ifn(abs(employment_start_date) > 1e6, datepart(employment_start_date), employment_start_date), yymmdd10.);
  else empstart = '2020-01-01';
  if not missing(application_dt) then
    appdate = put(ifn(abs(application_dt) > 1e6, datepart(application_dt), application_dt), yymmdd10.);
  else appdate = '2024-06-30';

  /* 1. applicant */
  g = '[{"metadata":[{"ApplicantID":"string"},{"ApplicantRole":"string"},{"CustomerID":"string"},{"Country":"string"}]},{"data":[["';
  applicantDataGrid = cats(g, pid, '","crd_PRI","","US"]]}]');

  /* 2. individual */
  g = '[{"metadata":[{"LinkedApplicantID":"string"},{"DateOfBirth":"string"},{"Dependants":"decimal"},{"VisaStatus":"string"}]},{"data":[["';
  individualDataGrid = cats(g, pid, '","', dob, '",', put(dep, best12.), ',"crd_NOTNEEDED"]]}]');

  /* 3. income */
  g = '[{"metadata":[{"LinkedApplicantID":"string"},{"IncomeAmount":"decimal"},{"IncomeCurrency":"string"},{"IncomeFrequency":"string"},{"IncomeType":"string"}]},{"data":[["';
  incomeDataGrid = cats(g, pid, '",', put(income, best12.), ',"USD","crd_MONTHLY","crd_SALARY"]]}]');

  /* 4. expenditure */
  g = '[{"metadata":[{"LinkedApplicantID":"string"},{"ExpenseAmount":"decimal"},{"ExpenseCurrency":"string"},{"ExpenseFrequency":"string"},{"ExpenseType":"string"}]},{"data":[["';
  expenditureDataGrid = cats(g, pid, '",', put(expense, best12.), ',"USD","crd_MONTHLY","crd_LIVING"]]}]');

  /* 5. credit bureau */
  g = cats('[{"metadata":[{"LinkedApplicantID":"string"},{"BureauID":"decimal"},{"BureauScore":"decimal"},',
           '{"BureauInquiries30":"decimal"},{"BureauInquiries90":"decimal"},{"BureauDefaults":"decimal"},',
           '{"BureauDefaultAmount":"decimal"},{"BureauDelinquentAmount":"decimal"},{"BureauPublicRecords":"decimal"},',
           '{"BureauPublicRecordAmount":"decimal"},{"BureauTotalInstallmentAmount":"decimal"},',
           '{"BureauTotalLiabilityBalance":"decimal"},{"BureauUnsecuredBalanceAmount":"decimal"}]},{"data":[["');
  creditBureauDataGrid = cats(g, pid, '",', put(aid, best12.), ',', put(bscore, best12.), ',',
        put(coalesce(inquiries_30_days, 0), best12.), ',', put(coalesce(inquiries_90_days, 0), best12.), ',',
        put(coalesce(defaults_count, 0), best12.), ',', put(defamt, best12.), ',', put(delamt, best12.), ',',
        put(coalesce(public_records_count, 0), best12.), ',', put(pubamt, best12.), ',',
        put(inst, best12.), ',', put(bal, best12.), ',', put(unsec, best12.), ']]}]');

  /* 6. existing account (current status 0, worst 12m as status) */
  g = '[{"metadata":[{"LinkedApplicantID":"string"},{"DelinquencyStatus":"decimal"},{"WorstDelinquency12Mths":"decimal"},{"TotalLiabilityBalance":"decimal"}]},{"data":[["';
  existingAccountDataGrid = cats(g, pid, '",0,', put(wd, best12.), ',', put(bal, best12.), ']]}]');

  /* 7. existing account details */
  g = cats('[{"metadata":[{"LinkedApplicantID":"string"},{"DepositAmount":"decimal"},{"DepositAmount_1":"decimal"},',
           '{"DepositAmount_2":"decimal"},{"DebitAmount":"decimal"},{"DebitAmount_1":"decimal"},{"DebitAmount_2":"decimal"}]},{"data":[["');
  existingAccountDetailsDataGrid = cats(g, pid, '",', put(income, best12.), ',', put(income, best12.), ',', put(income, best12.), ',',
        put(expense, best12.), ',', put(expense, best12.), ',', put(expense, best12.), ']]}]');

  /* 8. employment (TEMPORARY: every row crd_EMPLOYED) */
  g = '[{"metadata":[{"LinkedApplicantID":"string"},{"EmploymentStatus":"string"},{"EmploymentStartDate":"string"},{"EmploymentEndDate":"string"}]},{"data":[["';
  employmentDataGrid = cats(g, pid, '","crd_EMPLOYED","', empstart, '","2099-12-31"]]}]');

  /* 9. asset */
  g = '[{"metadata":[{"LinkedApplicantID":"string"},{"AssetValue":"decimal"}]},{"data":[["';
  assetDataGrid = cats(g, pid, '",', put(assets, best12.), ']]}]');

  /* 10. liability */
  g = '[{"metadata":[{"LinkedApplicantID":"string"},{"LiabilityAmount":"decimal"}]},{"data":[["';
  liabilityDataGrid = cats(g, pid, '",', put(liab, best12.), ']]}]');

  /* scalar columns */
  CHANNEL                  = upcase(channel);
  ApplicationID            = strip(put(aid, best12.));
  ApplicationDate          = appdate;
  ApplicantID              = pid;
  CustomerID               = strip(put(customer_rk, 15.));      /* real customer key, every row */
  ApplicationTimestamp     = application_ts;
  RequestTimestamp         = application_ts;
  ApplicationCurrentStatus = '';
  /* TEMPORARY product mapping by income band */
  if      income >= 10000 then ProductCode = 'crd_PLATINUM';
  else if income >= 3000  then ProductCode = 'crd_GOLD';
  else                         ProductCode = 'crd_SILVER';
  SimulationFlag           = 'Y';
  crd_preset_viyabaseurl   = '';                                 /* blank on purpose: no Cirrus calls */
  useUDModel               = 'Yes';
  RequestFrom              = 'RLA';
  RequestedCurrency        = 'USD';
  %if &scaled = 1 %then %do;
    mult = 1 + 12 * (rand('uniform') ** 1.6);
    if rand('uniform') < 0.85 then mult = min(mult, 0.5 * requested_term);
    RequestedAmount        = max(round(income * mult), 1000);
    RequestedDownPayment   = min(round(coalesce(requested_down_payment, 0) * f), round(0.3 * RequestedAmount));
  %end;
  %else %do;
    RequestedAmount        = requested_amount;
    RequestedDownPayment   = coalesce(requested_down_payment, 0);
  %end;
  RequestedTerm            = requested_term;
  RequestedInterestRate    = requested_interest_rate;
  RequestedLTV             = requested_ltv;
  _primary_bureau_score    = bscore;
  _primary_dependents      = dep;

  /* for the standalone 4.1 scorecard test: map these by hand there */
  sc_age                   = age;
  sc_assets                = assets;
  sc_worst_delinq_12m      = wd;
  sc_emp_duration_mths     = 0;

  keep CHANNEL ENTITY PRIORITY ApplicationID ApplicationDate ApplicantID ApplicationCurrentStatus
       ProductCode PRODUCT_CATEGORY SimulationFlag crd_preset_viyabaseurl useUDModel RequestFrom
       LOAN_PURPOSE LAST_NAME CustomerID RequestedCurrency ApplicationTimestamp RequestTimestamp
       applicantDataGrid individualDataGrid incomeDataGrid expenditureDataGrid creditBureauDataGrid
       existingAccountDataGrid existingAccountDetailsDataGrid employmentDataGrid assetDataGrid
       liabilityDataGrid
       RequestedAmount RequestedTerm RequestedInterestRate RequestedDownPayment RequestedLTV
       _primary_bureau_score _primary_dependents
       sc_age sc_assets sc_worst_delinq_12m sc_emp_duration_mths;
run;

/* the flow's column names are ProductCategory, LoanPurpose, LastName */
data work.crd;
  set work.crd(rename=(PRODUCT_CATEGORY=ProductCategory LOAN_PURPOSE=LoanPurpose LAST_NAME=LastName));
run;

/* 3. quick look before loading --------------------------------------------------- */
proc means data=work.crd n nmiss min median max maxdec=0;
  var RequestedAmount _primary_bureau_score;
run;
proc freq data=work.crd; tables ProductCategory ProductCode / nocum; run;
proc print data=work.crd(obs=3);
  var ApplicationID ApplicantID CustomerID ApplicationDate RequestTimestamp individualDataGrid;
run;

/* 4. load into CAS with varchar columns, promoted -------------------------------- */
proc casutil incaslib="rm_mdl" outcaslib="rm_mdl";
  droptable casdata="TMP_T300D" quiet;
  droptable casdata="&outname" quiet;
  load data=work.crd casout="TMP_T300D";
quit;

data rm_mdl.&outname(promote=yes);
  set rm_mdl.TMP_T300D(rename=(
     applicantDataGrid=a_ individualDataGrid=b_ incomeDataGrid=c_
     expenditureDataGrid=d_ creditBureauDataGrid=e_ existingAccountDataGrid=f_
     existingAccountDetailsDataGrid=g_ employmentDataGrid=h_
     assetDataGrid=i_ liabilityDataGrid=j_));
  length applicantDataGrid individualDataGrid incomeDataGrid expenditureDataGrid
         creditBureauDataGrid existingAccountDataGrid existingAccountDetailsDataGrid
         employmentDataGrid assetDataGrid liabilityDataGrid varchar(4000)
         sc_education sc_emp_type sc_marital_status sc_res_status varchar(100);
  applicantDataGrid=strip(a_); individualDataGrid=strip(b_); incomeDataGrid=strip(c_);
  expenditureDataGrid=strip(d_); creditBureauDataGrid=strip(e_); existingAccountDataGrid=strip(f_);
  existingAccountDetailsDataGrid=strip(g_); employmentDataGrid=strip(h_);
  assetDataGrid=strip(i_); liabilityDataGrid=strip(j_);
  sc_education=''; sc_emp_type=''; sc_marital_status=''; sc_res_status='';
  drop a_ b_ c_ d_ e_ f_ g_ h_ i_ j_;
run;

/* 5. final checks: rows, every row has CustomerID, ids look like 300030 / 100030, dates look real */
proc sql;
  select count(*) as n_rows, sum(not missing(CustomerID)) as with_customerid,
         count(distinct ApplicantID) as distinct_applicants,
         min(_primary_bureau_score) as min_bureau, max(_primary_bureau_score) as max_bureau
  from rm_mdl.&outname;
quit;
proc print data=rm_mdl.&outname(obs=5);
  var ApplicationID ApplicantID CustomerID ApplicationDate RequestTimestamp RequestedAmount;
run;
