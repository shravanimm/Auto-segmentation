/* ============================================================================
   dq_blockers.sas
   (was %dq_tech2_blockers in the old 10_dq_macros.sas)

   EDA-style blocker rules:
     high_missing   : completeness_pct < &missing_thresh
     zero_variance  : cardinality_count <= 1

   Called by: dq_calc_wrapper.sas
   ============================================================================ */
%macro dq_blockers(profile=, out=, missing_thresh=50);

    data &out;
        set &profile;
        length rule $20 detail $200;
        if completeness_pct < &missing_thresh then do;
            rule = "high_missing";
            detail = catx(' ', put(completeness_pct,8.1), "% complete -", missing_count, "rows missing");
            output;
        end;
        if cardinality_count <= 1 then do;
            rule = "zero_variance";
            detail = catx(' ', "Only", cardinality_count, "unique value(s) - zero predictive signal");
            output;
        end;
        keep name rule detail;
    run;

%mend dq_blockers;
