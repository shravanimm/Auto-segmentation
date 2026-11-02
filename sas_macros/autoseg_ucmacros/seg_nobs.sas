/* ============================================================================
   seg_nobs.sas
   Function-style macro: number of observations in a dataset (0 if it does not
   exist). Usage:  %let n = %seg_nobs(work.mytable);
   ============================================================================ */
%macro seg_nobs(ds);
    %local dsid n rc;
    %let n = 0;
    %if %sysfunc(exist(&ds)) %then %do;
        %let dsid = %sysfunc(open(&ds));
        %let n    = %sysfunc(attrn(&dsid, nlobs));
        %let rc   = %sysfunc(close(&dsid));
    %end;
    &n
%mend seg_nobs;
