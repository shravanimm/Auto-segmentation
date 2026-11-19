/* build_t300b_all_in_one.sas
   RLA_CRD_T300B = RLA_CRD_T300 (unchanged, same 300 applications) + 8 extra columns for the
   standalone "CRD - 4.1 - Application Scorecard_RM_int" test.
   Extra columns are named sc_* so the full flow does not pick them up by name.
   Runs inside CAS (FedSQL) so the varchar grid columns stay varchar. */

cas buildsess;
libname rm_mdl cas caslib="rm_mdl" sessref=buildsess;

proc fedsql sessref=buildsess;
  create table rm_mdl.RLA_CRD_T300B{options replace=true} as
  select t.*,
         a.age                                      as sc_age,
         coalesce(a.liquid_assets, 0)               as sc_assets,
         ceil(coalesce(a.worst_delinquency_12m,0)/30) as sc_worst_delinq_12m,
         0                                          as sc_emp_duration_mths,
         cast('' as varchar(100))                   as sc_education,
         cast('' as varchar(100))                   as sc_emp_type,
         cast('' as varchar(100))                   as sc_marital_status,
         cast('' as varchar(100))                   as sc_res_status
  from rm_mdl.RLA_CRD_T300 as t
  left join rm_mdl.RLA_APPLICATION as a
    on floor(cast(t.ApplicantID as double) / 10000) = a.application_rk;
quit;

proc casutil sessref=buildsess;
  promote casdata="RLA_CRD_T300B" incaslib="rm_mdl" outcaslib="rm_mdl";
quit;

/* checks: expect 300 rows, no missing age */
proc sql;
  select count(*) as rows,
         sum(sc_age is missing) as missing_age,
         sum(_primary_bureau_score is missing) as missing_bureau
  from rm_mdl.RLA_CRD_T300B;
quit;
