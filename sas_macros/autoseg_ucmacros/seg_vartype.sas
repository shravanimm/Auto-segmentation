/* ============================================================================
   seg_vartype.sas
   Function-style macro: returns N (numeric) or C (character) for a variable.
   Mirrors pandas is_numeric_dtype() in the Python code: AutoSlicer decides
   "numeric bins" vs "one predicate per category" from the column's physical
   type, NOT from the schema's categorical_cols list.
   Usage:  %let t = %seg_vartype(ds=work._sg_dev, var=age);
   ============================================================================ */
%macro seg_vartype(ds=, var=);
    %local dsid vnum t rc;
    %let t = ;
    %let dsid = %sysfunc(open(&ds));
    %if &dsid %then %do;
        %let vnum = %sysfunc(varnum(&dsid, &var));
        %if &vnum > 0 %then %let t = %sysfunc(vartype(&dsid, &vnum));
        %let rc = %sysfunc(close(&dsid));
    %end;
    &t
%mend seg_vartype;
