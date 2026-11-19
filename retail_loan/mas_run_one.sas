/* mas_run_one.sas
   Builds the request body for ONE application from rm_mdl.RLA_CRD_T300D and sends it to the published MAS module
   "CRD Credit Application Flow_new1_0" (module id: crd credit application flow_new1_0).

   Step 1 (do_execute=0): VALIDATE only. This checks the body against the module's inputs; it does NOT run the flow
           and writes nothing.
   Step 2 (do_execute=1): EXECUTE. This runs the flow and, because of the Record contacts node, writes a record to the
           subject contact database. Tell Abhishek / Sumedha first.

   gridmode = raw    -> the data grids are sent as JSON arrays
   gridmode = string -> the data grids are sent as JSON text inside a string (use if validation rejects 'raw') */

%let appid      = 124788;                  /* an application that reaches the scorecard (see CRD_T23 output) */
%let gridmode   = raw;
%let do_execute = 0;
%let host       = https://d125618.contour.rci1352a-m1.tsr-rci-ciaws.hpos.rnd.sas.com;
%let module     = crd%nrstr(%20)credit%nrstr(%20)application%nrstr(%20)flow_new1_0;

cas masrun;
libname rm_mdl clear;
libname rm_mdl cas caslib="rm_mdl" sessref=masrun;

/* ---------- build the request body ---------- */
%macro s(name, col);   /* string input */
  line = cats("{""name"":""&name"",""value"":""", strip(&col), """},"); put line;
%mend;
%macro n(name, col);   /* numeric input */
  line = cats("{""name"":""&name"",""value"":", ifc(missing(&col), "null", strip(put(&col, best32.))), "},"); put line;
%mend;
%macro g(name, col);   /* data grid input */
  %if &gridmode = raw %then %do;
    line = cats("{""name"":""&name"",""value"":", strip(&col), "},");
  %end;
  %else %do;
    line = cats("{""name"":""&name"",""value"":""", tranwrd(strip(&col), '"', '\"'), """},");
  %end;
  put line;
%mend;

%macro eg(name);       /* empty data grid: column header, zero rows */
  %if &gridmode = raw %then %do;
    line = "{""name"":""&name"",""value"":[{""metadata"":[{""LinkedApplicantID"":""string""}]},{""data"":[]}]},";
  %end;
  %else %do;
    line = "{""name"":""&name"",""value"":""[{\""metadata\"":[{\""LinkedApplicantID\"":\""string\""}]},{\""data\"":[]}]""},";
  %end;
  put line;
%mend;

filename body temp lrecl=32767;
data _null_;
  set rm_mdl.RLA_CRD_T300D(where=(ApplicationID = "&appid"));
  file body lrecl=32767;
  length line $32767 st $20;
  st = "crd_CREATED";
  put '{"inputs":[';
  %s(applicationid_,        ApplicationID)
  %s(applicantid_,          ApplicantID)
  %s(customerid_,           CustomerID)
  %s(applicationdate_,      ApplicationDate)
  %s(applicationtimestamp_, ApplicationTimestamp)
  %s(requesttimestamp_,     RequestTimestamp)
  %s(applicationcurrentstatus_, st)
  %s(channel_,              CHANNEL)
  %s(entity_,               ENTITY)
  %s(priority_,             PRIORITY)
  %s(lastname_,             LastName)
  %s(loanpurpose_,          LoanPurpose)
  %s(productcategory_,      ProductCategory)
  %s(productcode_,          ProductCode)
  %s(requestfrom_,          RequestFrom)
  %s(requestedcurrency_,    RequestedCurrency)
  %s(simulationflag_,       SimulationFlag)
  %s(crd_preset_viyabaseurl_, crd_preset_viyabaseurl)
  %n(requestedamount_,        RequestedAmount)
  %n(requesteddownpayment_,   RequestedDownPayment)
  %n(requestedinterestrate_,  RequestedInterestRate)
  %n(requestedltv_,           RequestedLTV)
  %n(requestedterm_,          RequestedTerm)
  %n(_primary_bureau_score_,  _primary_bureau_score)
  %n(_primary_dependents_,    _primary_dependents)
  %g(applicantdatagrid_,      applicantDataGrid)
  %g(individualdatagrid_,     individualDataGrid)
  %g(incomedatagrid_,         incomeDataGrid)
  %g(expendituredatagrid_,    expenditureDataGrid)
  %g(creditbureaudatagrid_,   creditBureauDataGrid)
  %g(existingaccountdatagrid_, existingAccountDataGrid)
  %g(existingaccountdetailsdatagrid_, existingAccountDetailsDataGrid)
  %g(employmentdatagrid_,     employmentDataGrid)
  %g(assetdatagrid_,          assetDataGrid)
  %g(liabilitydatagrid_,      liabilityDataGrid)
  /* inputs the module requires but our test table does not have: placeholders / empty grids */
  put '{"name":"applicationorigin_","value":"RLA"},';
  put '{"name":"creditrange_","value":"UNKNOWN"},';
  put '{"name":"refinanceflag_","value":"N"},';
  put '{"name":"crd_customer_industry_","value":"crd_OTHER"},';
  put '{"name":"balancetransferamt_","value":0},';
  %eg(addressdatagrid_)
  %eg(contactdetaildatagrid_)
  %eg(creditlinedatagrid_)
  %eg(defaultdatagrid_)
  %eg(inquirydatagrid_)
  %eg(publicrecorddatagrid_)
  line = cats("{""name"":""useudmodel_"",""value"":""", strip(useUDModel), """}"); put line;
  put ']}';
run;

/* ---------- send it ---------- */
filename resp temp;

%macro send;
  %if &do_execute = 1 %then %do;
    %put NOTE: EXECUTING the module (writes a subject contact record);
    proc http url="&host/microanalyticScore/modules/&module/steps/execute"
         method="POST" in=body out=resp oauth_bearer=sas_services;
      headers "Content-Type"="application/json" "Accept"="application/json";
    run;
  %end;
  %else %do;
    %put NOTE: VALIDATING only (does not run the flow);
    proc http url="&host/microanalyticScore/commons/validations/modules/&module/steps/execute"
         method="POST" in=body out=resp oauth_bearer=sas_services;
      headers "Content-Type"="application/json" "Accept"="application/json";
    run;
  %end;
%mend;
%send;

%put NOTE: HTTP status = &SYS_PROCHTTP_STATUS_CODE;
data _null_;
  infile resp lrecl=32767 length=l; input line $varying32767. l;
  if _n_ <= 40 then put line;      /* first part of the response */
run;

/* after an EXECUTE: print the key outputs (names are lower case in the module) */
%macro show;
  %if &do_execute = 1 %then %do;
    libname r json fileref=resp;
    proc sql;
      select name, substr(strip(value), 1, 200) as value
      from r.outputs
      where lowcase(name) in ('applicationcurrentstatus','errorcode','errordescription','applicationscore',
        '_risksegment','_customerflag','_ageprimaryapplicant','_totalincomeprimaryapplicant',
        '_totalexpensesprimaryapplicant','_debttoincomeratio','_requestedmonthlyinstallment',
        '_dispnetincprimaryapplicant','_unsecuredexposure','_approvedamount','_approvedrate',
        '_approvedterm','decisionreasoncodes');
    quit;
  %end;
%mend;
%show;

/* after a FAILED execute (HTTP 400 or higher): list the distinct "not found" messages, e.g. missing treatment-group modules */
%macro errs;
  %if &SYS_PROCHTTP_STATUS_CODE >= 400 %then %do;
    libname e json fileref=resp;
    proc sql;
      select distinct substr(message, 1, 200) as message
      from e.errors
      where index(message, 'Module context') > 0 or index(message, 'not found') > 0;
    quit;
  %end;
%mend;
%errs;
