/* flatten_contacts.sas
   Flattens the contact JSON that the Record contacts node puts in rt_Record_Contacts1 (one JSON per decision)
   into one row per decision, for the RM decision history.
   Input : the output table of a scoring test of CRD Credit Application Flow_new (set testname below)
   Output: rm_mdl.CRD_CONTACTS_FLAT (session table) + a printout. UNTESTED pattern matching: check the printout. */

%let testname = FLOW_NEW_TEST2;       /* upper case part of the output table name, e.g. FLOW_NEW_TEST2 */

cas flat1;
libname rm_mdl clear;
libname rm_mdl cas caslib="rm_mdl" sessref=flat1;

/* 0. find the test output and copy it into this session */
proc cas;
  table.tableInfo result=r / caslib="rm_mdl";
  saveresult r dataout=work.ti;
quit;

%let src=;
proc sql noprint;
  select strip(Name) into :src trimmed from work.ti
  where index(upcase(Name),"&testname._") and index(upcase(Name),"_OUTPUT");
quit;
%put NOTE: src=&src;

proc cas;
  table.copyTable / table={caslib="rm_mdl", name="&src"},
                    casout={caslib="rm_mdl", name="CONTACT_SRC", replace=true};
quit;

/* 1. one row per decision, one column per tracked variable */
%macro v(var, name);
  if prxmatch("/\{""name"":""&name"",/", json) then
    &var = strip(prxchange("s/.*\{""name"":""&name"",""dataType"":""[a-z]+"",""value"":""([^""]*)""\}.*/$1/", -1, json));
  else &var = '';
%mend;

data work.contacts;
  set rm_mdl.CONTACT_SRC(keep=ApplicationID rt_Record_Contacts1);
  length json $32767 subject_id channel response_code revision_id $60
         applicant_id customer_id application_date status risk_segment error_code $40
         score_txt amount_txt rate_txt term_txt $40;
  json = rt_Record_Contacts1;

  subject_id    = strip(prxchange('s/.*"subjectId":"([^"]*)".*/$1/', -1, json));
  channel       = strip(prxchange('s/.*"channel":"([^"]*)".*/$1/', -1, json));
  response_code = strip(prxchange('s/.*"responseTrackingCode":"([^"]*)".*/$1/', -1, json));
  revision_id   = strip(prxchange('s/.*"objectRevisionId":"([^"]*)".*/$1/', -1, json));

  %v(applicant_id,     ApplicantID)
  %v(customer_id,      CustomerID)
  %v(application_date, ApplicationDate)
  %v(status,           ApplicationCurrentStatus)
  %v(risk_segment,     _RiskSegment)
  %v(error_code,       ErrorCode)
  %v(score_txt,        ApplicationScore)
  %v(amount_txt,       _ApprovedAmount)
  %v(rate_txt,         _ApprovedRate)
  %v(term_txt,         _ApprovedTerm)

  application_score = input(score_txt, ?? best32.);
  approved_amount   = input(amount_txt, ?? best32.);
  approved_rate     = input(rate_txt,  ?? best32.);
  approved_term     = input(term_txt,  ?? best32.);
  application_rk    = input(subject_id, ?? best32.);
  keep application_rk subject_id applicant_id customer_id application_date status risk_segment error_code
       application_score approved_amount approved_rate approved_term channel response_code revision_id;
run;

proc print data=work.contacts(obs=10); run;
proc freq data=work.contacts; tables status risk_segment error_code / missing; run;

/* 2. keep a copy in CAS for later joins (session table; promote it if you want to keep it) */
data rm_mdl.CRD_CONTACTS_FLAT;
  set work.contacts;
run;
