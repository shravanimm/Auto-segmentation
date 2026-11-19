/* patch_age_gender.sas
   Manager-approved: replace the constant GENDER ('M') and DATE_OF_BIRTH_DT (1985-01-01) in
   BANKCRFM.RETAIL_LOAN_APPLICATIONS with random values, so GENDER has M and F and AGE varies.
   - Reads the table that is already published (keeps application_rk, customer_rk, applicant_rk,
     valid_start_dt and every other column as they are). Do NOT rerun load_retail_loan_applications.sas
     instead of this, it would drop those extra columns.
   - Takes a backup first: BANKCRFM.RETAIL_LOAN_APPLICATIONS_BKP.
   - Age is random, uniform 21-65 at the application date, and does not depend on the outcome. */

cas pa1;
caslib _all_ assign;

/* 1. backup */
data CASUSER.RLA_BKP;
  set bankcrfm.retail_loan_applications;
run;

proc casutil incaslib="CASUSER" outcaslib="BANKCRFM";
  droptable incaslib="BANKCRFM" casdata="RETAIL_LOAN_APPLICATIONS_BKP" quiet;
  save casdata="RLA_BKP" casout="RETAIL_LOAN_APPLICATIONS_BKP" replace;
quit;

/* 2. random gender and date of birth (single thread in WORK so the seed is repeatable) */
data work.rla;
  set bankcrfm.retail_loan_applications;
  if _n_ = 1 then call streaminit(2026);
  if rand('uniform') < 0.5 then gender = 'M'; else gender = 'F';
  _age = 21 + floor(45 * rand('uniform'));                       /* 21 to 65 */
  _dob = intnx('year', datepart(application_dt), -_age, 'same')
         - floor(364 * rand('uniform'));                         /* spread the birthday over the year */
  date_of_birth_dt = dhms(_dob, 0, 0, 0);
  format date_of_birth_dt nldatm21.;
  drop _age _dob;
run;

/* 3. checks before publishing */
proc freq data=work.rla;
  tables gender / nocum;
run;

data work.agechk;
  set work.rla(keep=application_dt date_of_birth_dt);
  age_chk = floor(yrdif(datepart(date_of_birth_dt), datepart(application_dt), 'AGE'));
run;

proc means data=work.agechk n min max mean;
  var age_chk;
run;

/* 4. republish under the same name */
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
