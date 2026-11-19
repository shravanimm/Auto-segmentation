/* promote_rla_original.sas
   Puts the new key columns into the ORIGINAL table rm_mdl.RLA_APPLICATION (same name, same caslib,
   promoted/global like before), using the verified copy rm_mdl.RLA_APPLICATION_V2.
   Added columns: applicant_rk, customer_rk, customer_key, valid_start_dt, application_ts.
   Run build_rla_v2_keys.sas first so RLA_APPLICATION_V2 exists.

   Part A = backup + checks (safe, changes nothing).
   Part B = the swap. Run it only when Part A shows equal row counts and the backup exists.
   Shared table: tell the colleagues who use RLA_APPLICATION before running Part B.
   After Part B, refresh the data definition in Risk Modeling so the new columns show up. */

cas rlaswap;

/* ---------------- Part A: backup and checks ---------------- */
proc cas;
  table.dropTable / caslib="rm_mdl", name="RLA_APPLICATION_BKP_20261117", quiet=true;
  table.copyTable / table={caslib="rm_mdl", name="RLA_APPLICATION"},
                    casout={caslib="rm_mdl", name="RLA_APPLICATION_BKP_20261117", promote=true};
  /* also write the backup to disk; if this errors the caslib may not be file-backed - tell me */
  table.save / table={caslib="rm_mdl", name="RLA_APPLICATION_BKP_20261117"},
               caslib="rm_mdl", name="RLA_APPLICATION_BKP_20261117.sashdat", replace=true;
quit;

proc fedsql sessref=rlaswap;
  select 'original' as tbl, count(*) as n_rows, count(distinct application_rk) as n_keys from rm_mdl.RLA_APPLICATION
  union all
  select 'backup', count(*), count(distinct application_rk) from rm_mdl.RLA_APPLICATION_BKP_20261117
  union all
  select 'v2', count(*), count(distinct application_rk) from rm_mdl.RLA_APPLICATION_V2;
quit;
/* expect 4720 rows and 4720 keys on all three lines */

/* ---------------- Part B: the swap (run only after Part A looks right) ---------------- */
/*
proc cas;
  table.dropTable / caslib="rm_mdl", name="RLA_APPLICATION";
  table.copyTable / table={caslib="rm_mdl", name="RLA_APPLICATION_V2"},
                    casout={caslib="rm_mdl", name="RLA_APPLICATION", promote=true};
  table.save / table={caslib="rm_mdl", name="RLA_APPLICATION"},
               caslib="rm_mdl", name="RLA_APPLICATION.sashdat", replace=true;
quit;

proc cas;
  table.columnInfo / table={caslib="rm_mdl", name="RLA_APPLICATION"};
quit;
*/
/* To undo: drop RLA_APPLICATION and copyTable RLA_APPLICATION_BKP_20261117 back to RLA_APPLICATION with promote=true. */
