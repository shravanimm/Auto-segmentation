/* ============================================================================
   seg_add_explain.sas
   Makes a technique's _segments / _rules tables self-explanatory by adding
     condition             (rules table)   each condition as exact SAS WHERE text
     Segment_Where_Clause  (segments)      the whole rule as an executable WHERE expression
     Segment_Summary       (segments)      one plain-English paragraph
     Membership_Type       (segments)      EXACT_RULE | NEAREST_CENTROID
     Membership_Note       (segments)      how missing values are treated
   closure    : LEFT  -> numeric interval  lower <= x < upper   (AutoSlicer, trees, K-Means rules)
                RIGHT -> numeric interval  lower <  x <= upper   (Feature Binning)
   notmissing : Y -> numeric conditions also require the value to be non-missing (SAS treats a
                missing number as smaller than every number, so x < 5 would otherwise be TRUE)
   fbmode     : Y -> Feature Binning: the categories of a bin are OR-ed:  f in ('a','b')
                (a missing category becomes  or missing(f) )
   sigvar     : name of the significance flag column in the segments table
   Text arguments must not contain commas or semicolons.
   ============================================================================ */
%macro seg_add_explain(seg=, rules=, closure=LEFT, notmissing=Y, member_type=EXACT_RULE, member_note=,
                       sigvar=Statistically_Significant, fbmode=N);

    %local lop uop;
    %if %upcase(&closure) = LEFT %then %do; %let lop = >=; %let uop = <; %end;
    %else %do; %let lop = >; %let uop = <=; %end;

    %if %seg_nobs(&seg) = 0 %then %return;

    /* ---- exact condition per rule row ---- */
    data &rules;
        set &rules;
        length condition $400 _lo _hi $200;
        condition = '';
        if ptype = 'N' then do;
            _lo = ''; _hi = '';
            if not lo_inf and not missing(lower) then _lo = catx(' ', feature, "&lop", strip(put(lower, best32.)));
            if not hi_inf and not missing(upper) then _hi = catx(' ', feature, "&uop", strip(put(upper, best32.)));
            condition = catx(' and ', _lo, _hi);
            %if %upcase(&notmissing) = Y %then %do;
                condition = catx(' and ', cats('not missing(', strip(feature), ')'), condition);
            %end;
        end;
        else if ptype = 'C' then condition = catx(' ', feature, '=', quote(strip(value), "'"));
        else if ptype = 'X' then condition = catx(' ', feature, 'ne', quote(strip(value), "'"));
        else if ptype = 'M' then condition = cats('missing(', strip(feature), ')');
        drop _lo _hi;
    run;

    /* ---- whole WHERE clause per segment ---- */
    data _ex_w(keep=Rank Segment_Where_Clause);
        set &rules;
        by Rank;
        length Segment_Where_Clause $2000 _inlist $1500 _infeat $64;
        retain Segment_Where_Clause _inlist _infeat _hasmiss;
        if first.Rank then do; Segment_Where_Clause = ''; _inlist = ''; _infeat = ''; _hasmiss = 0; end;
        %if %upcase(&fbmode) = Y %then %do;
            if ptype = 'C' then do;
                _infeat = feature;
                if value = '__MISSING__' then _hasmiss = 1;
                else _inlist = catx(',', _inlist, quote(strip(value), "'"));
            end;
            else Segment_Where_Clause = catx(' and ', Segment_Where_Clause, condition);
            if last.Rank then do;
                if _infeat ne '' then do;
                    if _inlist ne '' and _hasmiss then
                        Segment_Where_Clause = catx(' and ', Segment_Where_Clause,
                            cat('(', strip(_infeat), ' in (', strip(_inlist), ') or missing(', strip(_infeat), '))'));
                    else if _inlist ne '' then
                        Segment_Where_Clause = catx(' and ', Segment_Where_Clause,
                            cat(strip(_infeat), ' in (', strip(_inlist), ')'));
                    else
                        Segment_Where_Clause = catx(' and ', Segment_Where_Clause, cats('missing(', strip(_infeat), ')'));
                end;
                output;
            end;
        %end;
        %else %do;
            Segment_Where_Clause = catx(' and ', Segment_Where_Clause, condition);
            if last.Rank then output;
        %end;
    run;

    /* ---- plain-English summary + membership notes ---- */
    proc sort data=&seg; by Rank; run;
    data &seg;
        merge &seg _ex_w;
        by Rank;
        length Segment_Summary $1200 Membership_Type $40 Membership_Note $200
               _p1 _p2 _p3 _p4 _p5 _p6 $300;
        Membership_Type = "&member_type";
        Membership_Note = "&member_note";

        _p1 = cat(strip(put(Dev_Count, comma12.)), ' development rows (', strip(put(100 * Dev_Pct, 6.1)),
                   ' percent of dev) vs ', strip(put(Mon_Count, comma12.)), ' monitoring rows (',
                   strip(put(100 * Mon_Pct, 6.1)), ' percent of monitoring).');

        _p2 = '';
        if not missing(Dev_Gini) and not missing(Mon_Gini) then
            _p2 = cat('Gini ', ifc(Mon_Gini < Dev_Gini, 'fell', 'rose'), ' from ', strip(put(Dev_Gini, 6.3)),
                       ' to ', strip(put(Mon_Gini, 6.3)), '.');
        _p3 = '';
        if not missing(Dev_KS) and not missing(Mon_KS) then
            _p3 = cat('KS ', ifc(Mon_KS < Dev_KS, 'fell', 'rose'), ' from ', strip(put(Dev_KS, 6.3)),
                       ' to ', strip(put(Mon_KS, 6.3)), '.');
        _p4 = '';
        if not missing(Dev_BR) and not missing(Mon_BR) then
            _p4 = cat('Default rate ', ifc(Mon_BR > Dev_BR, 'rose', 'fell'), ' from ', strip(put(100 * Dev_BR, 6.1)),
                       ' to ', strip(put(100 * Mon_BR, 6.1)), ' percent.');

        _p5 = '';
        %if %upcase(&fbmode) = Y %then %do;
            _p5 = cat('This bin is defined on feature ', strip(Root_Cause_Feature), '; its size shifted by PSI ',
                       strip(put(Root_Cause_PSI, 6.3)), '.');
        %end;
        %else %do;
            if not missing(Root_Cause_Feature) then
                _p5 = cat('Feature drifting most inside the segment: ', strip(Root_Cause_Feature), ' (PSI ',
                           strip(put(Root_Cause_PSI, 6.3)), ').');
        %end;

        _p6 = ifc(&sigvar = 1, 'Statistically significant after multiple-testing correction.',
                  'Not statistically significant.');

        Segment_Summary = catx(' ', _p1, _p2, _p3, _p4, _p5, _p6);
        drop _p1-_p6;
    run;

%mend seg_add_explain;
