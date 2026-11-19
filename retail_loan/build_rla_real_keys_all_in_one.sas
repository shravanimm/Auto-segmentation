/* build_rla_real_keys_all_in_one.sas
   Starting from the ORIGINAL rm_mdl.RLA_APPLICATION (103 columns, no customer/applicant key), builds the version with
   the real RM keys and publishes it under the same name.

   Adds 5 columns:
     customer_rk    real customer key  = source customer_id  (application_id + 100000)
     applicant_rk   real applicant key = source applicant_id (application_id + 200000)
     customer_key   customer_rk as text (for the CRD flow's CustomerID)
     application_ts application_dt as text yyyy-mm-ddThh:mm:ss
     valid_start_dt = application_dt (the as-of date), formatted NLDATM21 like the other date columns

   do_swap=0 : build RLA_APPLICATION_NEW and run the checks only (live table untouched)
   do_swap=1 : also back up the live table and replace it (shared table: tell colleagues first)
   Run it ONLY when RLA_APPLICATION still has its original 103 columns. If it already has 108 columns
   (customer_rk, applicant_rk ...), the keys are in place and this script is not needed. */

%let do_swap = 0;
%let stamp   = 20261117;

cas rlakeys;

/* ---------- 1. key lookup from the source table ---------- */
proc cas;
  table.dropTable / caslib="rm_mdl", name="RLA_KEYS", quiet=true;
quit;

proc fedsql sessref=rlakeys;
  create table rm_mdl.RLA_KEYS{options replace=true} as
  select r.application_rk,
         s.customer_id  as customer_rk,
         s.applicant_id as applicant_rk,
         cast(cast(s.customer_id as bigint) as varchar(20)) as customer_key
  from rm_mdl.RLA_APPLICATION as r
  join bankcrfm.RETAIL_LOAN_APPLICATIONS as s
    on r.application_rk = s.application_id;
quit;

/* ---------- 2. build the new table: every original column + the 5 new ones ---------- */
proc cas;
  table.dropTable / caslib="rm_mdl", name="RLA_APPLICATION_NEW", quiet=true;

  source ds;
    data RLA_APPLICATION_NEW(caslib='rm_mdl' promote=yes);
      length application_ts varchar(19);
      merge RLA_APPLICATION(caslib='rm_mdl')
            RLA_KEYS(caslib='rm_mdl');
      by application_rk;
      application_ts = put(application_dt, e8601dt19.);
      valid_start_dt = application_dt;
      format customer_rk applicant_rk 15. valid_start_dt nldatm21.;
    run;
  endsource;

  datastep.runCode / code=ds;

  table.alterTable / caslib="rm_mdl" name="RLA_APPLICATION_NEW"
    columns={
      {name="application_ts", label="APPLICATION_TS"},
      {name="valid_start_dt", label="VALID_START_DT"},
      {name="customer_rk",    label="CUSTOMER_RK"},
      {name="applicant_rk",   label="APPLICANT_RK"},
      {name="customer_key",   label="CUSTOMER_KEY"}
    };
quit;

/* ---------- 3. checks: expect 4720 rows, no null keys, both offsets 4720, 108 columns ---------- */
proc fedsql sessref=rlakeys;
  select count(*) as n_rows,
         count(distinct application_rk) as n_apps,
         sum(case when customer_rk  is null then 1 else 0 end) as null_customer_rk,
         sum(case when applicant_rk is null then 1 else 0 end) as null_applicant_rk,
         sum(case when customer_rk  = application_rk + 100000 then 1 else 0 end) as customer_offset_ok,
         sum(case when applicant_rk = application_rk + 200000 then 1 else 0 end) as applicant_offset_ok
  from rm_mdl.RLA_APPLICATION_NEW;
quit;

proc fedsql sessref=rlakeys;
  select application_rk, customer_rk, applicant_rk, customer_key, application_ts, valid_start_dt
  from rm_mdl.RLA_APPLICATION_NEW limit 8;
quit;

proc cas;
  table.columnInfo / table={caslib="rm_mdl", name="RLA_APPLICATION_NEW"};
quit;

/* ---------- 4. publish under the original name (only when do_swap=1) ---------- */
%macro publish;
  %if &do_swap = 1 %then %do;
    proc cas;
      /* backup of the live table */
      table.dropTable / caslib="rm_mdl", name="RLA_APPLICATION_BKP_&stamp", quiet=true;
      table.copyTable / table={caslib="rm_mdl", name="RLA_APPLICATION"},
                        casout={caslib="rm_mdl", name="RLA_APPLICATION_BKP_&stamp", promote=true};

      /* replace it */
      table.dropTable / caslib="rm_mdl", name="RLA_APPLICATION";
      table.copyTable / table={caslib="rm_mdl", name="RLA_APPLICATION_NEW"},
                        casout={caslib="rm_mdl", name="RLA_APPLICATION", promote=true};
      table.save / table={caslib="rm_mdl", name="RLA_APPLICATION"},
                   caslib="rm_mdl", name="RLA_APPLICATION.sashdat", replace=true;
      table.columnInfo / table={caslib="rm_mdl", name="RLA_APPLICATION"};
    quit;
  %end;
  %else %put NOTE: do_swap=0, the live table was not changed.;
%mend;
%publish;

/* To undo: drop RLA_APPLICATION and copyTable RLA_APPLICATION_BKP_&stamp back to RLA_APPLICATION with promote=true. */
