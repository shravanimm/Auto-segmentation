/* build_scorecard_test_table.sas
   Test input for "CRD - 4.1 - Application Scorecard_RM_int" (standalone decision).
   One row per application in RLA_CRD_T300, with all 11 inputs the decision reads.
   Text inputs are blank: only the non-model branch (useUDModel='No') uses them. */

cas buildsess;
libname rm_mdl cas caslib="rm_mdl" sessref=buildsess;

proc sql;
  create table work.sc as
  select t.ApplicantID,
         a.age                                  as _AgePrimaryApplicant,
         t._primary_bureau_score                as _primary_bureau_score,
         t._primary_dependents                  as _primary_dependents,
         coalesce(a.liquid_assets,0)            as _TotalAssetsPrimaryApplicant,
         ceil(coalesce(a.worst_delinquency_12m,0)/30) as _WorstDelinquency12Mths,
         0                                      as _PrimaryApplicantEmplmntDurMths
  from rm_mdl.RLA_CRD_T300 as t
  left join rm_mdl.RLA_APPLICATION as a
    on floor(input(cats(t.ApplicantID), best32.)/10000) = a.application_rk;
quit;

data work.sc2;
  length ApplicantID $20 useUDModel $3
         _PrimaryApplicantEducation _PrimaryApplicantEmpType
         _PrimaryApplicantMarStatus _PrimaryApplicantResStatus $100;
  set work.sc;
  useUDModel = 'Yes';
  _PrimaryApplicantEducation = '';
  _PrimaryApplicantEmpType   = '';
  _PrimaryApplicantMarStatus = '';
  _PrimaryApplicantResStatus = '';
run;

/* load to CAS and promote; pick a new name each time (promoted tables cannot be replaced) */
%let outname=RLA_SC_T300;
data rm_mdl.&outname(promote=yes);
  set work.sc2;
run;

proc sql;
  select count(*) as rows,
         sum(_AgePrimaryApplicant is missing) as missing_age,
         sum(_primary_bureau_score is missing) as missing_bureau
  from rm_mdl.&outname;
quit;
