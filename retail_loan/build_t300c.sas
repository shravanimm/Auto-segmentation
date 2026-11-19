/* build_t300c.sas
   RLA_CRD_T300C = RLA_CRD_T300B (same 300 applications, all grids and sc_ columns) with these columns
   filled from the enriched RLA (rm_mdl.RLA_APPLICATION_V2):
     CustomerID           = customer_key   (every row: RLA treats every applicant as an existing customer)
     ApplicationTimestamp = application_ts (NOTE: the flow overwrites this with the scoring time at run time)
     RequestTimestamp     = application_ts (RLA application datetime, text yyyy-mm-ddThh:mm:ss; passes through)
   Runs as a FedSQL join inside CAS, so the varchar grid columns stay varchar.
   Run build_rla_v2_keys.sas first. */

cas t300c;

proc cas;
  table.dropTable / caslib="rm_mdl", name="RLA_CRD_T300C", quiet=true;
  table.columnInfo result=r / table={caslib="rm_mdl", name="RLA_CRD_T300B"};
  saveresult r dataout=work.t300b_cols;
quit;

/* every T300B column except CustomerID, which is replaced below */
proc sql noprint;
  select cats('t.', Column) into :collist separated by ', '
  from work.t300b_cols
  where upcase(Column) ne 'CUSTOMERID';
quit;

%let q=%str(%');
%let rts=%sysfunc(datetime(), e8601dt19.);
%put NOTE: RequestTimestamp = &rts;

proc fedsql sessref=t300c;
  create table rm_mdl.RLA_CRD_T300C{options replace=true} as
  select &collist,
         v.customer_key  as CustomerID,
         v.application_ts as ApplicationTimestamp,
         v.application_ts as RequestTimestamp
  from rm_mdl.RLA_CRD_T300B as t
  left join rm_mdl.RLA_APPLICATION_V2 as v
    on cast(t.ApplicationID as double) = v.application_rk;
quit;

proc casutil sessref=t300c;
  promote casdata="RLA_CRD_T300C" incaslib="rm_mdl" outcaslib="rm_mdl";
quit;

/* checks: expect 300 rows, 300 with CustomerID, 300 with ApplicationTimestamp */
proc fedsql sessref=t300c;
  select count(*) as n_rows,
         sum(case when CustomerID is not null and CustomerID <> '' then 1 else 0 end) as with_customerid,
         sum(case when ApplicationTimestamp is not null and ApplicationTimestamp <> '' then 1 else 0 end) as with_app_ts,
         sum(case when RequestTimestamp is not null and RequestTimestamp <> '' then 1 else 0 end) as with_request_ts
  from rm_mdl.RLA_CRD_T300C;
quit;

proc fedsql sessref=t300c;
  select ApplicationID, ApplicantID, CustomerID, ApplicationDate, ApplicationTimestamp, RequestTimestamp
  from rm_mdl.RLA_CRD_T300C limit 8;
quit;
