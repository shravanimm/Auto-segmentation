/* compare_crd_output_vs_rla.sas
   Gap check: CRD flow output (CRD_T19B) vs the RLA source table (RLA_APPLICATION), from the RM closed-loop view.
   Part 1: field map (which RLA column corresponds to which CRD output column) and whether each exists.
   Part 2: do the keys join, and do the values agree.
   Change sess/crd/rla if your names differ. Run part by part; if a step names a column your table does
   not have, it errors on that step only - tell me which. */

%let sess=exp2;          /* session that holds the CRD output copy */
%let crd=CRD_T19B;
%let rla=RLA_APPLICATION_V2;

cas &sess;

/* ---------- Step 0: (re)create the short copy of the Test19 output in this session ---------- */
%let testname=TEST20;
proc cas;
  table.tableInfo result=r / caslib="rm_mdl";
  saveresult r dataout=work.ti;
quit;

%let src=;
proc sql noprint;
  select strip(Name) into :src trimmed from work.ti
  where index(upcase(Name),"_&testname._") and index(upcase(Name),"_OUTPUT");
quit;
%put NOTE: src=&src;

proc cas;
  table.copyTable / table={caslib="rm_mdl", name="&src"},
                    casout={caslib="rm_mdl", name="&crd", replace=true};
quit;

/* ---------- Part 1: field map + existence ---------- */
proc cas;
  table.columnInfo result=a / table={caslib="rm_mdl", name="&rla"};
  saveresult a dataout=work.rla_cols;
  table.columnInfo result=b / table={caslib="rm_mdl", name="&crd"};
  saveresult b dataout=work.crd_cols;
quit;

data work.map;
  length role $12 rla_col crd_col $40;
  infile datalines dlm='|' truncover;
  input role $ rla_col $ crd_col $;
datalines;
key|application_rk|ApplicationID
key|applicant_rk|ApplicantID
key|customer_rk|CustomerID
time|valid_start_dt|ApplicationTimestamp
time|application_dt|ApplicationDate
time|-|RequestTimestamp
outcome|application_status|ApplicationCurrentStatus
outcome|outcome_cd|ApplicationCurrentStatus
outcome|reject_flg|ApplicationCurrentStatus
input|age|_AgePrimaryApplicant
input|bureau_score|_primary_bureau_score
input|dependants|_primary_dependents
input|total_monthly_income|_TotalIncomePrimaryApplicant
input|liquid_assets|_TotalAssetsPrimaryApplicant
input|worst_delinquency_12m|_WorstDelinquency12Mths
input|credit_range|CreditRange
score|-|ApplicationScore
score|-|_RiskSegment
model|-|(model name / version)
;
run;

proc sql;
  create table work.gap_map as
  select m.role, m.rla_col, m.crd_col,
         case when m.rla_col='-' then 'n/a'
              when exists (select 1 from work.rla_cols r where upcase(r.Column)=upcase(m.rla_col)) then 'yes' else 'NO' end as in_rla,
         case when exists (select 1 from work.crd_cols c where upcase(c.Column)=upcase(m.crd_col)) then 'yes' else 'NO' end as in_crd_output
  from work.map m;
  title "Field map: RLA vs CRD output";
  select * from work.gap_map;
quit;
title;

/* ---------- Part 2: key join and value agreement ---------- */
/* 2a. do CRD rows join to RLA on application_rk? */
proc fedsql sessref=&sess;
  select count(*) as n_crd,
         sum(case when a.application_rk is null then 1 else 0 end) as not_in_rla
  from rm_mdl.&crd as c
  left join rm_mdl.&rla as a on cast(c.ApplicationID as double) = a.application_rk;
quit;

/* 2b. does CRD ApplicantID equal RLA applicant_rk? (added in RLA_APPLICATION_V2) */
proc fedsql sessref=&sess;
  select count(*) as n_joined,
         sum(case when cast(c.ApplicantID as double) = a.applicant_rk then 1 else 0 end) as applicant_matches
  from rm_mdl.&crd as c
  join rm_mdl.&rla as a on cast(c.ApplicationID as double) = a.application_rk;
quit;

/* 2c. inputs: age / bureau / dependants should agree; income and assets were scaled in the test build */
proc fedsql sessref=&sess;
  select count(*) as n,
         sum(case when abs(c._AgePrimaryApplicant - a.age) <= 1 then 1 else 0 end) as age_ok,
         sum(case when c._primary_bureau_score = a.bureau_score then 1 else 0 end) as bureau_ok,
         sum(case when c._primary_dependents = a.dependants then 1 else 0 end) as dependants_ok,
         min(c._TotalIncomePrimaryApplicant / a.total_monthly_income) as income_ratio_min,
         avg(c._TotalIncomePrimaryApplicant / a.total_monthly_income) as income_ratio_avg,
         max(c._TotalIncomePrimaryApplicant / a.total_monthly_income) as income_ratio_max
  from rm_mdl.&crd as c
  join rm_mdl.&rla as a on cast(c.ApplicationID as double) = a.application_rk
  where a.total_monthly_income > 0;
quit;

/* 2d. outcome: historical RLA outcome vs simulated CRD decision */
proc fedsql sessref=&sess;
  select a.application_status, c.ApplicationCurrentStatus, count(*) as n
  from rm_mdl.&crd as c
  join rm_mdl.&rla as a on cast(c.ApplicationID as double) = a.application_rk
  group by a.application_status, c.ApplicationCurrentStatus
  order by 1, 2;
quit;
