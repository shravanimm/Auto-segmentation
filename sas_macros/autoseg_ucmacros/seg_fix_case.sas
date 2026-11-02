/* ============================================================================
   seg_fix_case.sas
   SAS variable names are case-insensitive, so `rename psi=PSI` does nothing (or
   errors) and `PSI = psi;` is a no-op. This macro gives the variables in
   &names the exact spelling listed there (e.g. psi -> PSI, delta_br -> Delta_BR)
   by routing each through a temporary name inside one DATA step.
   Only the spelling of the output column header changes - never the values.
   ============================================================================ */
%macro seg_fix_case(ds=, names=);

    %local n i nm ren back;
    %let n = %sysfunc(countw(&names, %str( )));
    %let ren  = ;
    %let back = ;
    %do i = 1 %to &n;
        %let nm = %scan(&names, &i, %str( ));
        %let ren  = &ren &nm=_fc&i;
        %let back = &back _fc&i=&nm;
    %end;

    data &ds;
        set &ds(rename=(&ren));
        rename &back;
    run;

%mend seg_fix_case;
