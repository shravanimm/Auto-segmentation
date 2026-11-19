/* build_crd_test_table.sas  (v2)
   Builds the CRD decision-flow test table from rm_mdl.RLA_APPLICATION in one go.
   Output: rm_mdl.RLA_CRD_T300 (300 rows, one per application, 10 JSON grid columns + scalar columns).

   v2 changes: finds the ID / date columns by name (RLA_APPLICATION may not use the CSV names),
   handles dates stored as SAS datetimes or as text, and stops with a clear error if no ID column exists.

   What it does
   1. Stratified sample of &N applications (proportional by product_category).
   2. Income spread: every money amount of an application is multiplied by one factor f
         f = 1 (30%), 0.5 (25%), 0.2 (20%), 0.08 (15%), 0.03 (10%)
   3. Delinquency: worst_delinquency_12m (days 0/60/90/120) -> status ceil(days/30); current status 0.
   4. Model inputs _primary_bureau_score and _primary_dependents as plain columns.
   5. CustomerID on every second row (existing-customer branch, CustomerFlag = N).
   6. Ten JSON grids in the datagrid package format [{"metadata":[...]},{"data":[[...]]}].
   TEMPORARY placeholders: ProductCode mapping, employment status mapping. */

%let N        = 300;
%let seed     = 20261116;
%let outname  = RLA_CRD_T300;

/* fresh, named CAS session (casauto can get stuck: "Session CASAUTO not recognized") */
cas buildsess;
libname rm_mdl cas caslib="rm_mdl" sessref=buildsess;

/* quick check: this must print 3 rows, otherwise stop here and tell me the message above */
proc print data=rm_mdl.RLA_APPLICATION(obs=3); var product_category; run;

/* 0. find the columns we need by name ------------------------------------------ */
%global idcol idtype dobcol dobtype escol estype adcol adtype agecol agetype;

%macro findcol(cands, outvar, outtype);
  %local i c n;
  %let &outvar  =;
  %let &outtype =;
  %let n = %sysfunc(countw(&cands, %str( )));
  %do i = 1 %to &n;
    %let c = %scan(&cands, &i, %str( ));
    %if %length(&&&outvar) = 0 %then %do;
      %let _hit  =;
      %let _type =;
      proc sql noprint;
        select name, type into :_hit trimmed, :_type trimmed
        from dictionary.columns
        where libname = 'RM_MDL' and upcase(memname) = 'RLA_APPLICATION'
          and upcase(name) = upcase("&c");
      quit;
      %if %length(&_hit) > 0 %then %do;
        %let &outvar  = &_hit;
        %let &outtype = &_type;
      %end;
    %end;
  %end;
%mend;

%findcol(application_rk application_id applicationid appl_id app_id id,          idcol,  idtype);
%findcol(age,                                                                     agecol, agetype);
%findcol(date_of_birth dob birth_date dateofbirth,                               dobcol, dobtype);
%findcol(employment_start_date emp_start_date employmentstartdate,               escol,  estype);
%findcol(application_dt application_date applicationdate,                       adcol,  adtype);
%put NOTE: columns found: id=&idcol (&idtype) dob=&dobcol (&dobtype) empstart=&escol (&estype) appdate=&adcol (&adtype);

%macro guard;
  %if %length(&idcol) = 0 %then %do;
    %put ERROR: no application id column found in RLA_APPLICATION. Run proc contents and tell me its name.;
    %abort cancel;
  %end;
%mend;
%guard;

/* date text (yyyy-mm-dd) from a datetime, a SAS date, or text */
%macro datetxt(col, type);
  %if %length(&col) = 0 %then %do; '' %end;
  %else %if %upcase(&type) = NUM %then %do;
    put(ifn(&col > 1e8, datepart(&col), &col), yymmdd10.)
  %end;
  %else %do; substr(strip(&col), 1, 10) %end;
%mend;

/* 1. stratified sample ----------------------------------------------------- */
data work.src;
  set rm_mdl.RLA_APPLICATION;
  %if %upcase(&idtype) = CHAR %then %do;
    application_id_n = input(strip(&idcol), best32.);
  %end;
  %else %do;
    application_id_n = &idcol;
  %end;
run;
proc sort data=work.src; by product_category; run;

proc surveyselect data=work.src out=work.samp method=srs n=&N seed=&seed;
  strata product_category / alloc=proportional;
run;

/* 2. build scalar columns and the ten grids ------------------------------------ */
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
         CustomerID $20 RequestedCurrency $3;

  /* income spread factor, same for every money amount of the row */
  /* base monthly incomes in RLA are about 15k-250k; the flow's income segments are roughly
     LOW < 1,500, MED 1,500-3,000, HIGH > 3,000, so scale into that range */
  u = rand('uniform');
  if      u < 0.12 then f = 0.02;
  else if u < 0.23 then f = 0.04;
  else if u < 0.35 then f = 0.07;
  else if u < 0.60 then f = 0.12;
  else if u < 0.85 then f = 0.30;
  else                  f = 0.60;

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

  bscore  = coalesce(bureau_score, 0);          /* missing bureau score -> 0 */
  dep     = coalesce(dependants, 0);
  wd      = ceil(coalesce(worst_delinquency_12m, 0) / 30);   /* days -> status */

  aid      = application_id_n;
  pid      = cats(put(aid, best12.), '0001');
  dob      = %datetxt(&dobcol, &dobtype);
  %if %length(&dobcol) = 0 and %length(&agecol) > 0 %then %do;
    /* no birth date column: derive one from AGE */
    dob = put(intnx('year', today(), -coalesce(&agecol, 40), 's'), yymmdd10.);
  %end;
  empstart = %datetxt(&escol, &estype);
  appdate  = %datetxt(&adcol, &adtype);
  if missing(dob)      or dob = '.'      then dob = '1980-01-01';
  if missing(empstart) or empstart = '.' then empstart = '2020-01-01';
  if missing(appdate)  or appdate = '.'  then appdate = '2024-06-30';

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

  /* 8. employment (TEMPORARY: every row crd_EMPLOYED, source employment_status not mapped yet) */
  g = '[{"metadata":[{"LinkedApplicantID":"string"},{"EmploymentStatus":"string"},{"EmploymentStartDate":"string"},{"EmploymentEndDate":"string"}]},{"data":[["';
  employmentDataGrid = cats(g, pid, '","crd_EMPLOYED","', empstart, '","2099-12-31"]]}]');

  /* 9. asset */
  g = '[{"metadata":[{"LinkedApplicantID":"string"},{"AssetValue":"decimal"}]},{"data":[["';
  assetDataGrid = cats(g, pid, '",', put(assets, best12.), ']]}]');

  /* 10. liability */
  g = '[{"metadata":[{"LinkedApplicantID":"string"},{"LiabilityAmount":"decimal"}]},{"data":[["';
  liabilityDataGrid = cats(g, pid, '",', put(liab, best12.), ']]}]');

  /* scalar columns (CHANNEL, ENTITY, PRIORITY, ProductCategory, LoanPurpose, LastName come from the source names) */
  CHANNEL                 = upcase(channel);
  ApplicationID           = strip(put(aid, best12.));
  ApplicationDate         = appdate;
  ApplicantID             = pid;
  ApplicationCurrentStatus = '';
  /* TEMPORARY product mapping: by income band, so the product's min age / min income policy fits */
  if      income >= 10000 then ProductCode = 'crd_PLATINUM';
  else if income >= 3000  then ProductCode = 'crd_GOLD';
  else                         ProductCode = 'crd_SILVER';
  SimulationFlag          = 'Y';
  crd_preset_viyabaseurl  = '';          /* blank on purpose: no Cirrus calls */
  useUDModel              = 'Yes';
  RequestFrom             = 'RLA_SYNTHETIC';
  if mod(_n_, 2) = 0 then CustomerID = cats('C', put(_n_, z6.));   /* existing customer */
  else CustomerID = '';
  RequestedCurrency       = 'USD';
  /* requested amount = income x multiplier (2..16); above 12 breaches the flow's max income multiplier */
  /* median multiplier about 5, about 5% above 12; 85% of rows capped so payment (amount/term) stays below income */
  mult                    = 1 + 12 * (rand('uniform') ** 1.6);
  if rand('uniform') < 0.85 then mult = min(mult, 0.5 * requested_term);
  RequestedAmount         = max(round(income * mult), 1000);
  RequestedTerm           = requested_term;
  RequestedInterestRate   = requested_interest_rate;
  RequestedDownPayment    = min(round(coalesce(requested_down_payment, 0) * f), round(0.3 * RequestedAmount));
  RequestedLTV            = requested_ltv;
  _primary_bureau_score   = bscore;
  _primary_dependents     = dep;
  spread_factor           = f;      /* kept for checking only; map nothing to it */

  keep CHANNEL ENTITY PRIORITY ApplicationID ApplicationDate ApplicantID ApplicationCurrentStatus
       ProductCode PRODUCT_CATEGORY SimulationFlag crd_preset_viyabaseurl useUDModel RequestFrom
       LOAN_PURPOSE LAST_NAME CustomerID RequestedCurrency
       applicantDataGrid individualDataGrid incomeDataGrid expenditureDataGrid creditBureauDataGrid
       existingAccountDataGrid existingAccountDetailsDataGrid employmentDataGrid assetDataGrid
       liabilityDataGrid
       RequestedAmount RequestedTerm RequestedInterestRate RequestedDownPayment RequestedLTV
       _primary_bureau_score _primary_dependents spread_factor;
run;

/* the flow's column names are ProductCategory, LoanPurpose, LastName */
data work.crd;
  set work.crd(rename=(PRODUCT_CATEGORY=ProductCategory LOAN_PURPOSE=LoanPurpose LAST_NAME=LastName));
run;

/* 3. quick look before loading ------------------------------------------------ */
proc means data=work.crd n nmiss min median max maxdec=0;
  var RequestedAmount _primary_bureau_score;
run;
proc freq data=work.crd; tables spread_factor ProductCategory / nocum; run;
proc print data=work.crd(obs=2);
  var ApplicantID ApplicationDate individualDataGrid creditBureauDataGrid existingAccountDataGrid employmentDataGrid;
run;

/* 4. load into CAS with varchar grid columns, promoted ------------------------- */
proc casutil incaslib="rm_mdl" outcaslib="rm_mdl";
  droptable casdata="TMP_T300" quiet;
  droptable casdata="&outname" quiet;
  load data=work.crd casout="TMP_T300";
quit;

data rm_mdl.&outname(promote=yes);
  set rm_mdl.TMP_T300(rename=(
     applicantDataGrid=a_ individualDataGrid=b_ incomeDataGrid=c_
     expenditureDataGrid=d_ creditBureauDataGrid=e_ existingAccountDataGrid=f_
     existingAccountDetailsDataGrid=g_ employmentDataGrid=h_
     assetDataGrid=i_ liabilityDataGrid=j_));
  length applicantDataGrid individualDataGrid incomeDataGrid expenditureDataGrid
         creditBureauDataGrid existingAccountDataGrid existingAccountDetailsDataGrid
         employmentDataGrid assetDataGrid liabilityDataGrid varchar(4000);
  applicantDataGrid=strip(a_); individualDataGrid=strip(b_); incomeDataGrid=strip(c_);
  expenditureDataGrid=strip(d_); creditBureauDataGrid=strip(e_); existingAccountDataGrid=strip(f_);
  existingAccountDetailsDataGrid=strip(g_); employmentDataGrid=strip(h_);
  assetDataGrid=strip(i_); liabilityDataGrid=strip(j_);
  drop a_ b_ c_ d_ e_ f_ g_ h_ i_ j_;
run;

/* 5. final checks: 300 rows, 150 with a CustomerID, ids look like 1383190001, dates look real ------- */
proc sql;
  select count(*) as rows, sum(not missing(CustomerID)) as with_customerid,
         min(_primary_bureau_score) as min_bureau, max(_primary_bureau_score) as max_bureau,
         count(distinct ApplicantID) as distinct_applicants
  from rm_mdl.&outname;
quit;
proc print data=rm_mdl.&outname(obs=5); var ApplicationID ApplicantID ApplicationDate CustomerID RequestedAmount; run;
