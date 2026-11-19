/* backup_rla.sas
   Backup of the data created for the retail loan application (RLA) work, 2026-10-26.
   Makes dated copies (.sashdat in BANKCRFM) of our tables and the shared table we appended to,
   and writes a CSV of the main table to SAS Content > My Folder.
   Nothing existing is overwritten or deleted: every copy has a new name with the date. */

cas bk1;
caslib _all_ assign;

%macro bkp(src, dst);
  data CASUSER.&dst.;
    set bankcrfm.&src.;
  run;

  proc casutil incaslib="CASUSER" outcaslib="BANKCRFM";
    droptable incaslib="BANKCRFM" casdata="&dst." quiet;
    save casdata="&dst." casout="&dst." replace;
  quit;
%mend;

/* our own table: 50,000 rows, 110 columns (age, gender, reject_flg added) */
%bkp(retail_loan_applications, RLA_BACKUP_20261026);

/* the shared table we appended the RLA applications to (state after the append) */
%bkp(all_application_dim, ALL_APP_DIM_AFTER_RLA_1026);

/* CSV copy of the main table, in SAS Content > My Folder */
filename out filesrvc folderpath="/Users/sastest1/My Folder" filename="retail_loan_applications_backup_20261026.csv";
proc export data=bankcrfm.retail_loan_applications outfile=out dbms=csv replace;
run;

/* what is on disk in BANKCRFM now (check the *_20261026 files are listed) */
proc casutil incaslib="BANKCRFM";
  list files;
quit;
