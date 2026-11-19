/* append_rla_to_all_application_dim.sas
   Adds the RLA applications to BANKCRFM.ALL_APPLICATION_DIM, the table RM reads the Retail Application
   population from. Run AFTER the RLA table is loaded and patched (load script, add_rk_and_valid_start,
   patch_age_gender, add_age_column, add_reject_flag).

   What it does, in order:
   1. Backs up the current table to disk (ALL_APPLICATION_DIM_BKP) and checks the expected row count.
   2. Finds the date columns (numeric, name ending _DT or _DTTM, optionally _2) and gives them the NLDATM21.
      format. Same values, only the format, so RM can compare them with our formatted dates
      (without this the build fails with: COALESCE types DOUBLE and TIMESTAMP cannot be matched).
   3. Builds the combined table privately in CASUSER: all existing rows + one row per RLA application.
   4. Verifies, and only then (step 5) replaces the live table.
   Shared table: tell the colleague before running step 5. */

cas app1;
caslib _all_ assign;

/* 1. backup (new environment: 27,887 rows, valid-from 01Jan1960 to 06Dec2013) */
data CASUSER.ALL_APPLICATION_DIM_BKP;
  set BANKCRFM.ALL_APPLICATION_DIM;
run;

proc casutil incaslib="CASUSER" outcaslib="BANKCRFM";
  droptable incaslib="BANKCRFM" casdata="ALL_APPLICATION_DIM_BKP" quiet;
  save casdata="ALL_APPLICATION_DIM_BKP" casout="ALL_APPLICATION_DIM_BKP" replace;
quit;

/* 2. date columns of the existing table */
proc sql noprint;
  select name into :dtcols separated by ' '
  from dictionary.columns
  where libname='BANKCRFM' and upcase(memname)='ALL_APPLICATION_DIM'
    and type='num'
    and prxmatch('/(_DT|_DTTM)(_2)?\s*$/', upcase(name));
quit;
%put &=dtcols;

/* 3. existing rows + RLA rows, in the structure of the existing table */
data CASUSER.ALL_APPLICATION_DIM;
  set BANKCRFM.ALL_APPLICATION_DIM
      BANKCRFM.RETAIL_LOAN_APPLICATIONS
        (in=new
         keep=application_id customer_id application_dt outcome_cd customer_type
              loan_purpose requested_amount requested_term channel request_source
         rename=(application_id=rla_app_id customer_id=rla_cust_id outcome_cd=rla_outcome
                 customer_type=rla_ctype channel=rla_channel));
  format &dtcols NLDATM21.;
  if new then do;
    APPLICATION_RK      = rla_app_id;
    APPLICATION_SK      = rla_app_id;
    APPLICATION_RK_2    = rla_app_id;
    CUSTOMER_RK         = rla_cust_id;
    CUSTOMER_RK_2       = rla_cust_id;
    APPLICATION_ID      = strip(put(rla_app_id, 12.));
    VALID_START_DTTM    = application_dt;
    VALID_START_DTTM_2  = application_dt;
    VALID_END_DTTM      = 87980687999;      /* 31Dec4747, open end like the old rows */
    VALID_END_DTTM_2    = 87980687999;
    if rla_ctype = 'BUSINESS_OWNER' then CUSTOMER_TYPE_CD = 'SME'; else CUSTOMER_TYPE_CD = 'IND';
    select (rla_outcome);
      when ('APPROVED')               OUTCOME_CD = 'ACC';
      when ('REJECTED')               OUTCOME_CD = 'REJ';
      when ('REFERRED')               OUTCOME_CD = 'REF';
      when ('CONDITIONALLY_APPROVED') OUTCOME_CD = 'CAP';
      otherwise                       OUTCOME_CD = '';
    end;
    PURPOSE_CD         = substr(loan_purpose,1,3);
    APPLIED_AMT        = requested_amount;
    LOAN_TERM_MTHS_CNT = requested_term;
    CHANNEL_CD         = substr(rla_channel,1,3);
    SOURCE_CD          = substr(request_source,1,5);
    APPLICANTS_CNT     = 1;
  end;
  drop rla_app_id rla_cust_id rla_outcome rla_ctype rla_channel loan_purpose
       requested_amount requested_term request_source;
run;

/* 4. verify (still private): expect 27,887 + 50,000 = 77,887 rows and as many distinct keys */
proc sql;
  select count(*) as n_rows, count(distinct APPLICATION_RK) as n_keys
  from CASUSER.ALL_APPLICATION_DIM;
  select CUSTOMER_TYPE_CD, OUTCOME_CD, count(*) as n
  from CASUSER.ALL_APPLICATION_DIM
  where APPLICATION_RK >= 100001
  group by 1,2;
quit;

/* 5. STOP: run the lines below only if the counts in step 4 are right.
      Publishes the combined table over the live one. */
/*
proc casutil incaslib="CASUSER" outcaslib="BANKCRFM";
  droptable incaslib="BANKCRFM" casdata="ALL_APPLICATION_DIM" quiet;
  save casdata="ALL_APPLICATION_DIM" casout="ALL_APPLICATION_DIM" replace;
  promote casdata="ALL_APPLICATION_DIM" casout="ALL_APPLICATION_DIM";
quit;
*/
