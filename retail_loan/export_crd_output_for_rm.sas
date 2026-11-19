/* export_crd_output_for_rm.sas
   Plain export of the CRD scoring test output. No columns added or removed.
   Change testname/outname below. */

%let testname=TEST16;
%let outname=CRD_T16;

cas buildsess;
libname rm_mdl cas caslib="rm_mdl" sessref=buildsess;

/* 1. find the output table by test name */
proc cas;
  table.tableInfo result=r / caslib="rm_mdl";
  saveresult r dataout=work.ti;
quit;

%let srcname=;
proc sql noprint;
  select strip(Name) into :srcname trimmed
  from work.ti
  where index(upcase(Name), "_&testname._") and index(upcase(Name),'_OUTPUT');
quit;
%put NOTE: source=&srcname;
%if %length(&srcname)=0 %then %do;
  %put ERROR: no output table found for &testname. Showing names containing OUTPUT:;
  proc print data=work.ti noobs; var Name; where index(upcase(Name),'OUTPUT'); run;
%end;

/* 2. copy to a short name (session scope) */
proc cas;
  table.copyTable / table={caslib="rm_mdl", name="&srcname"},
                    casout={caslib="rm_mdl", name="&outname", replace=true};
quit;

/* 3. row count and full column list */
proc sql;
  select count(*) as rows from rm_mdl.&outname;
quit;

proc contents data=rm_mdl.&outname out=work.cols(keep=varnum name type length) noprint; run;
proc sort data=work.cols; by varnum; run;
proc print data=work.cols noobs; run;

/* 4. export everything as CSV into your SAS Content "My Folder" (lockdown blocks ~ paths) */
filename outcsv filesrvc folderpath="/Users/sastest1/My Folder" filename="&outname..csv";
proc export data=rm_mdl.&outname outfile=outcsv dbms=csv replace;
run;
filename outcsv clear;
