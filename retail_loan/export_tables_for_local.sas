/* export_tables_for_local.sas
   Exports our tables to CSV files in SAS Content > My Folder so they can be downloaded to a local computer.
   Backups stored as .sashdat are loaded into memory first (SAS cannot read them from disk directly).
   Nothing is changed or deleted: the live and backup tables stay as they are. */

cas ex1;
caslib _all_ assign;

%macro load_and_export(sashdat, memname, csvname);
  proc casutil incaslib="BANKCRFM" outcaslib="CASUSER";
    load casdata="&sashdat..sashdat" casout="&memname." replace;
  quit;

  filename out filesrvc folderpath="/Users/sastest1/My Folder" filename="&csvname..csv";
  proc export data=casuser.&memname. outfile=out dbms=csv replace;
  run;
  filename out clear;
%mend;

/* our applications table as it is now (50,000 rows, 110 columns) */
%load_and_export(RLA_BACKUP_20261026, RLA_NOW, retail_loan_applications_20261026);

/* shared table AFTER we appended our applications */
%load_and_export(ALL_APP_DIM_AFTER_RLA_1026, ADIM_AFTER, all_application_dim_after_rla_1026);

/* shared table BEFORE the append, with the date-format fix (undo copy) */
%load_and_export(ALL_APPLICATION_DIM_BKP2, ADIM_BKP2, all_application_dim_bkp2);

/* shared table in its original state (oldest undo copy) */
%load_and_export(ALL_APPLICATION_DIM_BKP, ADIM_BKP, all_application_dim_bkp);

/* row counts of the tables just loaded, for a quick check */
proc sql;
  select 'RLA_NOW' as t, count(*) as n from casuser.rla_now
  union all select 'ADIM_AFTER', count(*) from casuser.adim_after
  union all select 'ADIM_BKP2', count(*) from casuser.adim_bkp2
  union all select 'ADIM_BKP', count(*) from casuser.adim_bkp;
quit;
