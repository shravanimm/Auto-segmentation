/* ============================================================================
   seg_apply_labels.sas
   Attaches a SAS column LABEL (from the data dictionary) to every column of every
   output table whose name starts with &prefix._ , so the tables explain themselves
   wherever they are opened (SAS Studio shows labels, Risk Modeling can show them too).
   Columns that are not in the dictionary keep their name. Values are never changed.
   prefix : e.g. seg      dict : the dictionary table written by seg_metric_dictionary
   ============================================================================ */
%macro seg_apply_labels(prefix=seg, dict=seg_metric_dictionary);

    %local tabs nt j t lbls;

    proc sql noprint;
        select memname into :tabs separated by ' ' from dictionary.tables
        where libname = 'WORK' and memtype = 'DATA'
          and substr(memname, 1, %eval(%length(&prefix) + 1)) = upcase("&prefix._")
          and memname ne upcase("&dict");
    quit;

    %let nt = %sysfunc(countw(&tabs, %str( )));
    %do j = 1 %to &nt;
        %let t = %scan(&tabs, &j, %str( ));
        %let lbls = ;
        proc sql noprint;
            select catx('=', c.name, quote(strip(d.label))) into :lbls separated by ' '
            from dictionary.columns c inner join &dict d on upcase(c.name) = upcase(d.column_name)
            where c.libname = 'WORK' and c.memname = "&t";
        quit;
        %if %length(&lbls) %then %do;
            proc datasets lib=work nolist nowarn;
                modify &t;
                label &lbls;
            quit;
        %end;
    %end;

%mend seg_apply_labels;
