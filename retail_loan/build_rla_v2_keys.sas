/* build_rla_v2_keys.sas
   Creates rm_mdl.RLA_APPLICATION_V2 = every row and column of rm_mdl.RLA_APPLICATION
   plus the keys and time columns the RM closed loop needs. The original table is NOT touched.

   New columns:
     customer_rk     = application_rk (CUSTOMER_ID is blank on all rows; every row is an existing customer)
     customer_key    customer_rk as text, for the flow's CustomerID
     applicant_rk    application_rk * 10000 + 1  (the same rule the CRD test uses for ApplicantID)
     valid_start_dt  = application_dt (datetime), the as-of date RM looks up on
     application_ts  application_dt as text yyyy-mm-ddThh:mm:ss (feeds the flow's ApplicationTimestamp)
   Needs only columns we saw in the RM copy: APPLICATION_RK, APPLICATION_DT, CUSTOMER_ID. */

cas rla2;

proc cas;
  table.dropTable / caslib="rm_mdl", name="RLA_APPLICATION_V2", quiet=true;

  source ds;
    data RLA_APPLICATION_V2(caslib='rm_mdl' promote=yes);
      set RLA_APPLICATION(caslib='rm_mdl');
      length application_ts varchar(19) customer_key varchar(20);
      /* RLA has no customer key (CUSTOMER_ID is blank on all rows and every applicant is an existing
         customer of 6.5-7 years), so each application is its own customer */
      customer_rk    = application_rk;
      customer_key   = strip(put(application_rk, 12.));
      applicant_rk   = application_rk * 10000 + 1;
      valid_start_dt = application_dt;
      application_ts = put(application_dt, e8601dt19.);
      format customer_rk applicant_rk 15. valid_start_dt datetime20.;
    run;
  endsource;

  datastep.runCode / code=ds;
quit;

/* checks */
proc fedsql sessref=rla2;
  select count(*) as n_v2 from rm_mdl.RLA_APPLICATION_V2;
  select count(*) as n_original from rm_mdl.RLA_APPLICATION;
quit;

proc fedsql sessref=rla2;
  select count(distinct application_rk) as distinct_application_rk,
         sum(case when customer_id is null or customer_id = '' then 1 else 0 end) as blank_customer_id,
         sum(case when customer_rk is null then 1 else 0 end) as null_customer_rk,
         count(distinct customer_id) as distinct_customer_id
  from rm_mdl.RLA_APPLICATION_V2;
quit;

proc fedsql sessref=rla2;
  select application_rk, applicant_rk, customer_rk, customer_key, application_ts
  from rm_mdl.RLA_APPLICATION_V2 limit 8;
quit;
