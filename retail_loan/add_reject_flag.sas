/* add_reject_flag.sas
   Adds a stored numeric target column REJECT_FLG (1 = REJECTED, 0 = any other outcome) to
   BANKCRFM.RETAIL_LOAN_APPLICATIONS. The scorecard's "calculate proportions" step counts events as
   target = 1 and non-events as target = 0, so the text column APPLICATION_STATUS gives 0 events.
   Run after add_age_column.sas. Keeps every other column. Backup: RETAIL_LOAN_APPLICATIONS_BKP3. */

cas pa4;
caslib _all_ assign;

data CASUSER.RLA_BKP3;
  set bankcrfm.retail_loan_applications;
run;

proc casutil incaslib="CASUSER" outcaslib="BANKCRFM";
  droptable incaslib="BANKCRFM" casdata="RETAIL_LOAN_APPLICATIONS_BKP3" quiet;
  save casdata="RLA_BKP3" casout="RETAIL_LOAN_APPLICATIONS_BKP3" replace;
quit;

data work.rla;
  set bankcrfm.retail_loan_applications;
  if upcase(strip(application_status)) = 'REJECTED' then reject_flg = 1;
  else reject_flg = 0;
run;

proc freq data=work.rla;
  tables application_status*reject_flg / norow nocol nopercent;
run;

data CASUSER.RETAIL_LOAN_APPLICATIONS;
  set work.rla;
run;

proc casutil incaslib="CASUSER" outcaslib="BANKCRFM";
  droptable incaslib="BANKCRFM" casdata="RETAIL_LOAN_APPLICATIONS" quiet;
  save casdata="RETAIL_LOAN_APPLICATIONS" casout="RETAIL_LOAN_APPLICATIONS" replace;
  promote casdata="RETAIL_LOAN_APPLICATIONS" casout="RETAIL_LOAN_APPLICATIONS";
quit;

proc cas;
  table.columnInfo / table={caslib="BANKCRFM", name="RETAIL_LOAN_APPLICATIONS"};
quit;
