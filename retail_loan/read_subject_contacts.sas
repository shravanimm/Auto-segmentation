/* read_subject_contacts.sas
   Reads the decision records from the subject contact service and flattens them into one row per decision:
   subject (application) id, keys, date, status, score, risk segment, offer, error code, channel, flow revision,
   and the decision time stamped by the service (creationTimeStamp).
   READ ONLY: it does not write or delete anything. First 100 records only (see the note about paging at the end).
   UNTESTED: the JSON table and column names are the ones the JSON engine normally creates; check the printout. */

%let host = https://d125618.contour.rci1352a-m1.tsr-rci-ciaws.hpos.rnd.sas.com;

filename resp temp;
proc http url="&host/subjectContacts/contacts?start=0&limit=100&sortBy=creationTimeStamp:ascending"
     method="GET" oauth_bearer=sas_services out=resp;
run;
%put NOTE: HTTP status = &SYS_PROCHTTP_STATUS_CODE;

libname c clear;
libname c json fileref=resp;
proc contents data=c._all_ nods; run;           /* shows ITEMS, ITEMS_OBJECTVARIABLES, ... */

/* one row per tracked variable -> one column per variable */
proc transpose data=c.items_objectvariables out=work.vars(drop=_name_);
  by ordinal_items;
  id name;
  var value;
run;

data work.contacts;
  merge c.items(keep=ordinal_items id subjectId channel creationTimeStamp responseTrackingCode objectRevisionId)
        work.vars;
  by ordinal_items;
  decision_dttm = input(substr(creationTimeStamp, 1, 19), e8601dt19.);
  format decision_dttm datetime20.;
  application_rk = input(subjectId, ?? best32.);
  approved_amount = input(_ApprovedAmount, ?? best32.);
  application_score = input(ApplicationScore, ?? best32.);
run;

proc print data=work.contacts;
  var application_rk decision_dttm channel ApplicationCurrentStatus application_score _RiskSegment
      approved_amount _ApprovedRate _ApprovedTerm ErrorCode;
run;

/* Paging: the service returns up to 100 per call. For more, repeat the call with start=100, 200, ...
   until the number of items returned is smaller than the limit. */
