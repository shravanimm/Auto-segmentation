/* add_rk_and_valid_start.sas
   Run right after load_retail_loan_applications.sas.
   Adds the key columns RM wants (names ending _RK) and an early valid-from date, in one pass.
   - application_rk / customer_rk / applicant_rk: copies of the ID columns (RM's Key dropdown offers _RK names)
   - valid_start_dt = 0 (01Jan1960): an early start date so the as-of lookup never lands before the record starts
   Take a backup of the table first if it already holds data you want to keep. */

cas rk1;
caslib _all_ assign;

data CASUSER.RETAIL_LOAN_APPLICATIONS;
  set BANKCRFM.RETAIL_LOAN_APPLICATIONS;
  application_rk = application_id;
  customer_rk    = customer_id;
  applicant_rk   = applicant_id;
  format application_rk customer_rk applicant_rk 12.;
  valid_start_dt = 0;                    /* 01Jan1960 */
  format valid_start_dt nldatm21.;
run;

proc casutil incaslib="CASUSER" outcaslib="BANKCRFM";
  droptable incaslib="BANKCRFM" casdata="RETAIL_LOAN_APPLICATIONS" quiet;
  save casdata="RETAIL_LOAN_APPLICATIONS" casout="RETAIL_LOAN_APPLICATIONS" replace;
  promote casdata="RETAIL_LOAN_APPLICATIONS" casout="RETAIL_LOAN_APPLICATIONS";
quit;

proc cas;
  table.columnInfo / table={caslib="BANKCRFM", name="RETAIL_LOAN_APPLICATIONS"};
quit;
