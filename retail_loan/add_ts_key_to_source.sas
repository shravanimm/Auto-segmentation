/* add_ts_key_to_source.sas
   Adds two columns to the SOURCE table BANKCRFM.RETAIL_LOAN_APPLICATIONS so that an RM rebuild of RLA_APPLICATION
   keeps them (the published rm_mdl.RLA_APPLICATION already has them):
     application_ts   application_dt as text yyyy-mm-ddThh:mm:ss (varchar 19)
     customer_key     customer_rk as text (varchar 20), for the CRD flow's CustomerID
   Nothing else is changed. valid_start_dt in the source stays as it is (0 = 01Jan1960, from add_rk_and_valid_start.sas);
   note the published RLA_APPLICATION has valid_start_dt = application_dt, so the two differ.

   Part A: backup + build the new table privately in CASUSER + checks (live table untouched).
   Part B: the swap (commented). Run it only when Part A looks right.
   Shared source table: tell the colleagues before Part B. */

cas srcfix;
caslib _all_ assign;

/* ---------------- Part A ---------------- */

/* 1. backup to disk (existing backups: _BKP, _BKP2, _BKP3) */
data CASUSER.RLA_BKP4;
  set BANKCRFM.RETAIL_LOAN_APPLICATIONS;
run;

proc casutil incaslib="CASUSER" outcaslib="BANKCRFM";
  droptable incaslib="BANKCRFM" casdata="RETAIL_LOAN_APPLICATIONS_BKP4" quiet;
  save casdata="RLA_BKP4" casout="RETAIL_LOAN_APPLICATIONS_BKP4" replace;
quit;

/* 2. build the new version privately (same name in CASUSER) */
data CASUSER.RETAIL_LOAN_APPLICATIONS;
  set BANKCRFM.RETAIL_LOAN_APPLICATIONS;
  length application_ts varchar(19) customer_key varchar(20);
  application_ts = put(application_dt, e8601dt19.);
  customer_key   = strip(put(customer_rk, 15.));
run;

/* 3. checks: expect 50,000 rows in both, 50,000 distinct customer_key, 2 more columns */
proc fedsql sessref=srcfix;
  select 'live' as tbl, count(*) as n_rows from bankcrfm.RETAIL_LOAN_APPLICATIONS
  union all
  select 'new', count(*) from casuser.RETAIL_LOAN_APPLICATIONS;
quit;

proc fedsql sessref=srcfix;
  select count(distinct customer_key) as distinct_customer_key,
         sum(case when application_ts is null or application_ts = '' then 1 else 0 end) as blank_ts
  from casuser.RETAIL_LOAN_APPLICATIONS;
quit;

proc fedsql sessref=srcfix;
  select application_id, customer_id, customer_key, application_dt, application_ts
  from casuser.RETAIL_LOAN_APPLICATIONS limit 8;
quit;

proc cas;
  table.columnInfo / table={caslib="BANKCRFM", name="RETAIL_LOAN_APPLICATIONS"};
  table.columnInfo / table={caslib="CASUSER",  name="RETAIL_LOAN_APPLICATIONS"};
quit;

/* ---------------- Part B: the swap (run only after Part A looks right) ---------------- */
/*
proc casutil incaslib="CASUSER" outcaslib="BANKCRFM";
  droptable incaslib="BANKCRFM" casdata="RETAIL_LOAN_APPLICATIONS" quiet;
  save casdata="RETAIL_LOAN_APPLICATIONS" casout="RETAIL_LOAN_APPLICATIONS" replace;
  promote casdata="RETAIL_LOAN_APPLICATIONS" casout="RETAIL_LOAN_APPLICATIONS";
quit;

proc cas;
  table.columnInfo / table={caslib="BANKCRFM", name="RETAIL_LOAN_APPLICATIONS"};
quit;
*/
/* To undo: load RETAIL_LOAN_APPLICATIONS_BKP4.sashdat and repeat the same save and promote. */
