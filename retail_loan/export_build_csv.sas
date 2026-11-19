/* export_build_csv.sas
   Exports the RM modeling data set (the build) RM_MDL.RLA_APPLICATION to a CSV in SAS Content > My Folder.
   Run it in RM > SAS Code Execution (that page has the RM_MDL connection; plain SAS Studio does not).
   Reads only, nothing is changed. */

data work.rla_build;
  set rm_mdl.rla_application;
run;

proc sql;
  select count(*) as n_rows from work.rla_build;
quit;

filename out filesrvc folderpath="/Users/sastest1/My Folder" filename="RLA_APPLICATION_build_31DEC2024.csv";
proc export data=work.rla_build outfile=out dbms=csv replace;
run;
filename out clear;
