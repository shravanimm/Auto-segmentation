/* ============================================================================
   dq_governance.sas
   (was %dq_tech3_governance in the old 10_dq_macros.sas)

   EDA-style governance rules:
     IDENTIFIER : uniqueness_pct >= &id_uniqueness_thresh, or name listed in id_cols
     LEAKAGE    : numeric, min>=0, max<=1, cardinality>=&leakage_card_min, not target
     PRIVACY    : name listed in private_cols (cannot be inferred from data alone -
                  pass the known-sensitive column list explicitly, e.g. private_cols=age region)

   Called by: dq_calc_wrapper.sas
   ============================================================================ */
%macro dq_governance(profile=, out=, id_cols=, private_cols=, target_col=,
                      id_uniqueness_thresh=99.9, leakage_card_min=50);

    data &out;
        set &profile;
        length risk_type $12 detail $200;

        if uniqueness_pct >= &id_uniqueness_thresh
           %if %length(&id_cols) %then or indexw(upcase("&id_cols"), upcase(trim(name))) > 0;
           then do;
            risk_type = "IDENTIFIER";
            detail = catx(' ', "Uniqueness", put(uniqueness_pct,8.1), "% - surrogate key, exclude from features");
            output;
        end;

        if type = 1 and min >= 0 and max <= 1 and cardinality_count >= &leakage_card_min
           %if %length(&target_col) %then and upcase(name) ne upcase("&target_col");
           then do;
            risk_type = "LEAKAGE";
            detail = "Bounded [0,1], high cardinality - resembles a model probability output";
            output;
        end;

        %if %length(&private_cols) %then %do;
        if indexw(upcase("&private_cols"), upcase(trim(name))) > 0
            then do;
            risk_type = "PRIVACY";
            detail = "Listed as a privacy-sensitive attribute";
            output;
        end;
        %end;

        keep name risk_type detail;
    run;

%mend dq_governance;
