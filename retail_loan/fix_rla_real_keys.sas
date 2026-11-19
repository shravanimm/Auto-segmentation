/* fix_rla_real_keys.sas
   Replaces the made-up keys in rm_mdl.RLA_APPLICATION with the real ones from the source table
   BANKCRFM.RETAIL_LOAN_APPLICATIONS (customer_id = application_id + 100000, applicant_id = application_id + 200000,
   the same customer key the append script put into ALL_APPLICATION_DIM as CUSTOMER_RK).
     customer_rk   = source customer_id
     applicant_rk  = source applicant_id
     customer_key  = customer_rk as text
   Everything else (valid_start_dt, application_ts, all original columns, formats, labels) is kept.
   Part A builds RLA_APPLICATION_V3 and checks it. Part B swaps it in (commented, run after Part A looks right). */

cas rlakeys;

/* ---------------- Part A ---------------- */

/* 1. backup of the table as it is now (original + current keys) */
proc cas;
  table.dropTable / caslib="rm_mdl", name="RLA_APPLICATION_BKP2_20261117", quiet=true;
  table.copyTable / table={caslib="rm_mdl", name="RLA_APPLICATION"},
                    casout={caslib="rm_mdl", name="RLA_APPLICATION_BKP2_20261117", promote=true};
quit;

/* 2. key lookup from the source */
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

/* 3. build V3 = current table with the three key columns replaced */
proc cas;
  table.dropTable / caslib="rm_mdl", name="RLA_APPLICATION_V3", quiet=true;

  source ds;
    data RLA_APPLICATION_V3(caslib='rm_mdl' promote=yes);
      merge RLA_APPLICATION(caslib='rm_mdl' drop=customer_rk customer_key applicant_rk)
            RLA_KEYS(caslib='rm_mdl');
      by application_rk;
      format customer_rk applicant_rk 15.;
    run;
  endsource;

  datastep.runCode / code=ds;

  table.alterTable / caslib="rm_mdl" name="RLA_APPLICATION_V3"
    columns={
      {name="applicant_rk", label="APPLICANT_RK"},
      {name="customer_rk",  label="CUSTOMER_RK"},
      {name="customer_key", label="CUSTOMER_KEY"}
    };
quit;

/* 4. checks: 4720 rows, 4720 distinct keys, no null keys, offsets as expected */
proc fedsql sessref=rlakeys;
  select count(*) as n_rows,
         count(distinct application_rk) as n_apps,
         sum(case when customer_rk  is null then 1 else 0 end) as null_customer_rk,
         sum(case when applicant_rk is null then 1 else 0 end) as null_applicant_rk,
         sum(case when customer_rk  = application_rk + 100000 then 1 else 0 end) as customer_offset_ok,
         sum(case when applicant_rk = application_rk + 200000 then 1 else 0 end) as applicant_offset_ok
  from rm_mdl.RLA_APPLICATION_V3;
quit;

proc fedsql sessref=rlakeys;
  select application_rk, customer_rk, applicant_rk, customer_key, application_ts, valid_start_dt
  from rm_mdl.RLA_APPLICATION_V3 limit 8;
quit;

proc cas;
  table.columnInfo / table={caslib="rm_mdl", name="RLA_APPLICATION_V3"};
quit;

/* ---------------- Part B: the swap (run only after Part A looks right) ---------------- */
/*
proc cas;
  table.dropTable / caslib="rm_mdl", name="RLA_APPLICATION";
  table.copyTable / table={caslib="rm_mdl", name="RLA_APPLICATION_V3"},
                    casout={caslib="rm_mdl", name="RLA_APPLICATION", promote=true};
  table.save / table={caslib="rm_mdl", name="RLA_APPLICATION"},
               caslib="rm_mdl", name="RLA_APPLICATION.sashdat", replace=true;
  table.columnInfo / table={caslib="rm_mdl", name="RLA_APPLICATION"};
quit;
*/
/* To undo: restore from RLA_APPLICATION_BKP2_20261117 (keys as of the first swap) or RLA_APPLICATION_BKP_20261117 (original). */
