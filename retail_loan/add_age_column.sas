/* add_age_column.sas
   Adds a stored AGE column (age in whole years at the application date) to
   BANKCRFM.RETAIL_LOAN_APPLICATIONS. Run after patch_age_gender.sas.
   Keeps every other column. Backup first: BANKCRFM.RETAIL_LOAN_APPLICATIONS_BKP2. */

cas pa3;
caslib _all_ assign;

data CASUSER.RLA_BKP2;
  set bankcrfm.retail_loan_applications;
run;

proc casutil incaslib="CASUSER" outcaslib="BANKCRFM";
  droptable incaslib="BANKCRFM" casdata="RETAIL_LOAN_APPLICATIONS_BKP2" quiet;
  save casdata="RLA_BKP2" casout="RETAIL_LOAN_APPLICATIONS_BKP2" replace;
quit;

data work.rla;
  set bankcrfm.retail_loan_applications;
  age = floor(yrdif(datepart(date_of_birth_dt), datepart(application_dt), 'AGE'));
run;

proc means data=work.rla n min max mean;
  var age;
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
