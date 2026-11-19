/* ============================================================================
   seg_detect_schema.sas
   AUTOMATIC COLUMN-ROLE DETECTION - SAS port of utils/schema_detection.py, so the
   trigger only has to name the data and the target.

   From the DEVELOPMENT table it decides, for every column:
     TARGET   given, or auto: binary column whose name looks like a target
     SCORE    model score: first numeric column matching, in tiers, predicted_pd /
              pd / probability / score names; fallbacks: probability-like, then any
              high-cardinality numeric
     WEIGHT   exposure: first numeric column named ead / exposure / balance / weight / amount
     ID       name looks like an identifier, or text/integer column unique in >98% of rows
     TIME     date / month / period / vintage / snapshot / year-like names
     SHAP     shap_* columns (used only for the SHAP-shift diagnostics)
     FEATURE  everything else -> FEATURE_NUMERIC or FEATURE_CATEGORICAL
              (text, or a number with <= sg_cfg_cat_max_card distinct values = categorical)
     EXCLUDED explicit exclusions (ead, predicted_pd, actual_default, monitoring_month,
              caller's exclude_cols) plus three SAFETY checks the Python did not have:
                - the column is missing (or has another type) in the monitoring table
                - the column is constant
                - suspected target leakage: single-feature |AUC - 0.5| >= sg_cfg_leak_auc
                - a text column with more than sg_cfg_max_cat_levels distinct values
   Anything the caller passes explicitly (score_col, weight_col, shap_cols, feature_cols,
   numeric_cols, categorical_cols, exclude_cols) overrides the detection for that item.

   OUTPUT  table &out : one row per column - role, plain-English reason, source
           (caller / auto-detected), distinct values, % missing, min, max, leak AUC
           global macro vars: sg_sc_target sg_sc_score sg_sc_weight sg_sc_shap
           sg_sc_features sg_sc_numeric sg_sc_categorical sg_sc_ids sg_sc_time
   Requires seg_config (sg_cfg_*). Column names are assumed to be standard SAS names.
   ============================================================================ */
%macro seg_sc_first(where=, into=);
    %let &into = ;
    proc sql outobs=1 noprint;
        select name into :&into trimmed from _sc_cat where &where order by varnum;
    quit;
%mend seg_sc_first;

%macro seg_sc_auc(data=, var=, target=, into=);
    %let &into = 0;
    data _sc_a1;
        set &data(keep=&target &var);
        where not missing(&var) and not missing(&target);
        _x = &var; _yy = &target;
    run;
    %if %seg_nobs(_sc_a1) >= 2 %then %do;
        proc rank data=_sc_a1 out=_sc_a2 ties=mean; var _x; ranks _r; run;
        proc sql noprint;
            select sum(_yy = 1), sum(_yy = 0), sum(case when _yy = 1 then _r else 0 end) format=best32.
              into :_sc_n1 trimmed, :_sc_n0 trimmed, :_sc_r1 trimmed from _sc_a2;
        quit;
        data _null_;
            if &_sc_n1 > 0 and &_sc_n0 > 0 then
                s = abs((&_sc_r1 - &_sc_n1 * (&_sc_n1 + 1) / 2) / (&_sc_n1 * &_sc_n0) - 0.5);
            else s = 0;
            call symputx("&into", put(s, best32.), 'G');
        run;
    %end;
%mend seg_sc_auc;

/* Screens one candidate column: how strongly it separates DEFAULTS (target strength) and
   how strongly it separates DEV from MONITORING rows (drift strength). Both are |AUC-0.5|.
   Categorical columns (text, or few distinct numbers) are first replaced by the per-level rate. */
%macro seg_sc_screen(dev=, mon=, var=, target=, cat=0, into_t=, into_d=);
    data _sc_d1;
        set &dev(keep=&var &target in=_a) &mon(keep=&var in=_m);
        _g = (_m = 1);
    run;
    %if &cat %then %do;
        proc sql;
            create table _sc_e1 as select &var as lv, avg(&target) as enc_t from _sc_d1 where _g = 0 group by &var;
            create table _sc_e2 as select &var as lv, avg(_g) as enc_d from _sc_d1 group by &var;
            create table _sc_e3 as
            select a.&target, a._g, b.enc_t, c.enc_d
            from _sc_d1 a left join _sc_e1 b on a.&var = b.lv left join _sc_e2 c on a.&var = c.lv;
        quit;
        %seg_sc_auc(data=_sc_e3, var=enc_t, target=&target, into=&into_t);
        %seg_sc_auc(data=_sc_e3, var=enc_d, target=_g, into=&into_d);
    %end;
    %else %do;
        %seg_sc_auc(data=_sc_d1, var=&var, target=&target, into=&into_t);
        %seg_sc_auc(data=_sc_d1, var=&var, target=_g, into=&into_d);
    %end;
%mend seg_sc_screen;

%macro seg_detect_schema(dev=, mon=, target_col=, score_col=, weight_col=, shap_cols=, feature_cols=,
                         numeric_cols=, categorical_cols=, exclude_cols=, out=seg_schema);

    %global sg_sc_target sg_sc_score sg_sc_weight sg_sc_shap sg_sc_features sg_sc_numeric
            sg_sc_categorical sg_sc_ids sg_sc_time;
    %global sg_sc_aucv sg_sc_aucd;
    %local i nc tier chk ss_k;

    %let sg_sc_target      = &target_col;
    %let sg_sc_score       = &score_col;
    %let sg_sc_weight      = &weight_col;
    %let sg_sc_shap        = ;
    %let sg_sc_features    = ;
    %let sg_sc_numeric     = ;
    %let sg_sc_categorical = ;
    %let sg_sc_ids         = ;
    %let sg_sc_time        = ;

    /* ---- 1. catalogue + per-column statistics (development table) ---- */
    proc contents data=&dev out=_sc_c0(keep=name type varnum) noprint; run;
    proc sort data=_sc_c0; by varnum; run;
    proc contents data=&mon out=_sc_cm(keep=name type) noprint; run;

    data _null_;
        set _sc_c0 end=_e;
        call symputx(cats('sc_n', _n_), name, 'L');
        call symputx(cats('sc_t', _n_), type, 'L');
        if _e then call symputx('nc', _n_, 'L');
    run;

    data _sc_stats;
        length name $64 n_miss 8 n_dist 8 vmin 8 vmax 8 n_frac 8 nobs 8;
        stop;
    run;
    %do i = 1 %to &nc;
        %if &&sc_t&i = 1 %then %do;
            proc sql;
                insert into _sc_stats
                select "&&sc_n&i", sum(missing(&&sc_n&i)), count(distinct &&sc_n&i),
                       min(&&sc_n&i), max(&&sc_n&i),
                       sum(not missing(&&sc_n&i) and mod(&&sc_n&i, 1) ne 0), count(*)
                from &dev;
            quit;
        %end;
        %else %do;
            proc sql;
                insert into _sc_stats
                select "&&sc_n&i", sum(missing(&&sc_n&i)), count(distinct &&sc_n&i), ., ., 0, count(*)
                from &dev;
            quit;
        %end;
    %end;

    proc sql;
        create table _sc_cat as
        select c.name, c.type, c.varnum, s.n_miss, s.n_dist, s.vmin, s.vmax, s.n_frac, s.nobs,
               case when m.name is not null and m.type = c.type then 1 else 0 end as in_mon
        from _sc_c0 c
             left join _sc_stats s on upcase(c.name) = upcase(s.name)
             left join _sc_cm m on upcase(c.name) = upcase(m.name)
        order by c.varnum;
    quit;

    /* ---- 2. name-pattern flags (the same regular expressions as schema_detection.py) ---- */
    data _sc_cat;
        set _sc_cat;
        length nm $64;
        nm = strip(name);
        f_id   = prxmatch('/(_rk$|^rk_|_key$|^key_|^id$|_id$|^id_|customer_?id|account_?id|application_?id|loan_?id|transaction_?id|contract_?id|policy_?id|member_?id|client_?id|party_?id|reference_?id|uuid|identifier)/i', nm) > 0
              or prxmatch('/(customer_?number|account_?number|application_?number|transaction_?number|loan_?number|contract_?number|policy_?number|member_?number|client_?number|reference_?number|customer_?key|account_?key|application_?key|transaction_?key)/i', nm) > 0;
        f_pii  = prxmatch('/(first_?name|middle_?name|last_?name|surname|full_?name|^name$|e_?mail|phone|mobile|street|postal|zip_?code|address|ssn|passport|national_?id|employer_name|job_title|^city$|_city$)/i', nm) > 0;
        f_post = prxmatch('/(outcome|decision|approv|reject|declin|application_status|record_status|^status$)/i', nm) > 0;
        f_time = prxmatch('/(_dt$|^dt_|_dttm$|_tm$|^month$|_month$|^month_|^period$|_period$|^period_|date|vintage|snapshot|as_of|timestamp|^year$|_year$|^year_)/i', nm) > 0;
        f_shap = prxmatch('/^shap[_\-]/i', nm) > 0;
        f_tgt  = prxmatch('/(reject_f|^target$|target_|_target$|^default$|default_|_default$|bad_flag|is_bad|^label$|label_|_label$|^outcome$|outcome_|_outcome$|^event$|event_|_event$)/i', nm) > 0;
        f_w    = prxmatch('/(^ead$|_ead$|^ead_|exposure|balance|^weight$|_weight$|^weight_|amount)/i', nm) > 0;
        t1 = prxmatch('/^(predicted_pd|pred_pd|model_score|pd_hat|prediction|predicted_probability|predicted_prob)$/i', nm) > 0;
        t2 = prxmatch('/(^pd$|_pd$|^pd_)/i', nm) > 0;
        t3 = prxmatch('/(probability|prob_|_prob$|proba|risk_score|model_output)/i', nm) > 0;
        t4 = prxmatch('/(^score$|score_|_score$)/i', nm) > 0;
        f_defx = (lowcase(nm) in ('predicted_pd', 'actual_default', 'monitoring_month', 'ead'));
        f_usrx = (lengthn(strip("&exclude_cols")) > 0 and indexw(upcase("&exclude_cols"), upcase(nm), ' ') > 0);
        uniq_ratio = (n_dist + (n_miss > 0)) / max(nobs, 1);
        f_idu  = (uniq_ratio > &sg_cfg_id_uniq) and (type = 2 or (type = 1 and n_frac = 0));
    run;

    /* ---- 3. TARGET ---- */
    %if %length(&target_col) %then %do;
        %let sg_sc_target = &target_col;
    %end;
    %else %do;
        %seg_sc_first(where=f_tgt = 1 and n_dist = 2, into=sg_sc_target);
        %if not %length(&sg_sc_target) %then
            %seg_sc_first(where=n_dist = 2 and type = 1 and vmin >= 0 and vmax <= 1 and n_frac = 0, into=sg_sc_target);
    %end;
    proc sql noprint; select count(*) into :chk trimmed from _sc_cat where upcase(name) = upcase("&sg_sc_target"); quit;
    %if not %length(&sg_sc_target) or &chk = 0 %then %do;
        %put ERROR: seg_detect_schema - target column "&sg_sc_target" not found in &dev - pass target_col=;
        %let syscc = 8;
        %return;
    %end;
    proc sql noprint; select type into :chk trimmed from _sc_cat where upcase(name) = upcase("&sg_sc_target"); quit;
    %if &chk ne 1 %then %do;
        %put ERROR: seg_detect_schema - target column &sg_sc_target must be numeric 0/1.;
        %let syscc = 8;
        %return;
    %end;

    /* ---- 4. SCORE ---- */
    %if not %length(&score_col) %then %do;
        %do tier = 1 %to 4;
            %if not %length(&sg_sc_score) %then
                %seg_sc_first(where=type = 1 and t&tier = 1 and upcase(name) ne upcase("&sg_sc_target"), into=sg_sc_score);
        %end;
        %if not %length(&sg_sc_score) %then
            %seg_sc_first(where=type = 1 and n_dist > &sg_cfg_cat_max_card and vmin >= 0 and vmax <= 1 and upcase(name) ne upcase("&sg_sc_target"), into=sg_sc_score);
        %if not %length(&sg_sc_score) %then
            %seg_sc_first(where=type = 1 and n_dist > &sg_cfg_cat_max_card and upcase(name) ne upcase("&sg_sc_target"), into=sg_sc_score);
    %end;
    %if not %length(&sg_sc_score) %then %do;
        %put ERROR: seg_detect_schema - no model score column detected - pass score_col=;
        %let syscc = 8;
        %return;
    %end;

    /* ---- 5. WEIGHT (optional) ---- */
    /* first numeric column (in table order) whose name looks like an exposure - a plain DATA step,
       with the name test written out here so it cannot depend on any earlier flag */
    %if not %length(&weight_col) %then %do;
        data _null_;
            set _sc_cat;
            if type = 1
               and prxmatch('/(^ead$|_ead$|^ead_|exposure|balance|^weight$|_weight$|^weight_|amount)/i', strip(name)) > 0
               and upcase(strip(name)) ne upcase("&sg_sc_target")
               and upcase(strip(name)) ne upcase("&sg_sc_score") then do;
                call symputx('sg_sc_weight', strip(name), 'G');
                stop;
            end;
        run;
        %put NOTE: seg_detect_schema - exposure weight auto-detected: [&sg_sc_weight] (empty = none found);
    %end;

    /* ---- 6. first-pass classification and the leakage screen ---- */
    data _sc_cat;
        set _sc_cat;
        is_tgt = (upcase(nm) = upcase("&sg_sc_target"));
        is_scr = (upcase(nm) = upcase("&sg_sc_score"));
        is_wgt = (lengthn(strip("&sg_sc_weight")) > 0 and upcase(nm) = upcase(strip("&sg_sc_weight")));
        is_idc = (f_id = 1 or f_idu = 1);
        %if %length(&shap_cols) %then %do;
            is_shp = (indexw(upcase("&shap_cols"), upcase(nm), ' ') > 0);
        %end;
        %else %do;
            is_shp = f_shap;
        %end;
        cand = (not (is_tgt or is_scr or is_wgt or is_idc or f_time or f_pii or f_post or is_shp or f_defx or f_usrx))
               and in_mon = 1 and n_dist > 1
               %if %length(&feature_cols) %then %do; and indexw(upcase("&feature_cols"), upcase(nm), ' ') > 0 %end;
               and not (type = 2 and n_dist > &sg_cfg_max_cat_levels);
    run;

    /* screen every candidate: target strength (leakage) and dev-vs-monitoring drift strength */
    data _sc_leak; length name $64 leak_auc 8 drift_auc 8; stop; run;
    %let ss_k = 0;
    data _null_;
        set _sc_cat end=_e;
        where cand = 1;
        k + 1;
        call symputx(cats('ss_n', k), name, 'L');
        call symputx(cats('ss_c', k), (type = 2 or n_dist <= &sg_cfg_cat_max_card), 'L');
        if _e then call symputx('ss_k', k, 'L');
    run;
    %do i = 1 %to &ss_k;
        %seg_sc_screen(dev=&dev, mon=&mon, var=&&ss_n&i, target=&sg_sc_target, cat=&&ss_c&i,
                       into_t=sg_sc_aucv, into_d=sg_sc_aucd);
        data _sc_l1; length name $64; name = "&&ss_n&i"; leak_auc = &sg_sc_aucv; drift_auc = &sg_sc_aucd; run;
        proc append base=_sc_leak data=_sc_l1 force; run;
    %end;

    /* ---- 7. rank the usable candidates; keep only the strongest sg_cfg_max_features ---- */
    proc sql;
        create table _sc_fin0 as
        select c.*, l.leak_auc, l.drift_auc from _sc_cat c left join _sc_leak l on upcase(c.name) = upcase(l.name)
        order by c.varnum;
        create table _sc_rk as
        select name, max(leak_auc, drift_auc) as strength from _sc_fin0
        where cand = 1 and not (leak_auc >= &sg_cfg_leak_auc)
        order by calculated strength desc, name;
    quit;
    data _sc_rk; set _sc_rk; feat_rank = _n_; run;
    proc sql;
        create table _sc_fin as
        select a.*, b.feat_rank, b.strength from _sc_fin0 a left join _sc_rk b on upcase(a.name) = upcase(b.name)
        order by a.varnum;
    quit;

    /* ---- 8. final roles with a plain-English reason ---- */
    data &out(keep=varnum column_name data_type role reason source n_distinct pct_missing min_value max_value leak_auc drift_auc feat_rank);
        set _sc_fin;
        length column_name $64 data_type $10 role $22 reason $240 source $14;
        column_name = nm;
        data_type = ifc(type = 1, 'numeric', 'character');
        n_distinct = n_dist;
        pct_missing = ifn(nobs > 0, 100 * n_miss / nobs, .);
        min_value = vmin; max_value = vmax;
        source = 'auto-detected';

        if is_tgt then do;
            role = 'TARGET';
            if lengthn(strip("&target_col")) > 0 then do; source = 'caller'; reason = 'Target (0/1 default flag) supplied by the caller'; end;
            else reason = 'Binary column whose name looks like a target / outcome flag';
        end;
        else if is_scr then do;
            role = 'SCORE';
            if lengthn(strip("&score_col")) > 0 then do; source = 'caller'; reason = 'Model score supplied by the caller'; end;
            else reason = 'Name matches a model-score pattern (predicted PD / PD / probability / score) - used to compute AUC, Gini, KS and calibration';
        end;
        else if is_wgt then do;
            role = 'WEIGHT';
            if lengthn(strip("&weight_col")) > 0 then do; source = 'caller'; reason = 'Exposure supplied by the caller'; end;
            else reason = 'Name matches an exposure / balance / weight pattern - used for exposure shares, never as a feature';
        end;
        else if is_idc then do;
            role = 'ID';
            if f_id then reason = 'Name looks like an identifier - never used as a feature or root cause';
            else reason = cat('Unique in ', strip(put(100 * uniq_ratio, 5.1)), '% of rows - treated as an identifier');
        end;
        else if f_time then do;
            role = 'TIME';
            reason = 'Name looks like a date / period / vintage - excluded so time cannot define a segment';
        end;
        else if f_pii then do;
            role = 'EXCLUDED';
            reason = 'Personal data (name / contact / address / employer) - never used as a segmentation feature';
        end;
        else if f_post then do;
            role = 'EXCLUDED';
            reason = 'Decision / outcome / status column - only known after the decision, so using it would leak the answer';
        end;
        else if is_shp then do;
            if in_mon = 1 then do;
                role = 'SHAP';
                reason = 'SHAP value column - used only for the SHAP-shift diagnostic, never as a segmentation feature';
            end;
            else do; role = 'EXCLUDED'; reason = 'SHAP column missing in the monitoring table - ignored'; end;
        end;
        else if f_defx or f_usrx then do;
            role = 'EXCLUDED';
            source = ifc(f_usrx and not f_defx, 'caller', 'default list');
            reason = 'On the exclusion list (ead / predicted_pd / actual_default / monitoring_month or caller exclude_cols)';
        end;
        else if in_mon ne 1 then do;
            role = 'EXCLUDED'; reason = 'Not present (with the same type) in the monitoring table';
        end;
        else if n_dist <= 1 then do;
            role = 'EXCLUDED'; reason = 'Constant column - cannot define a segment';
        end;
        else if type = 2 and n_dist > &sg_cfg_max_cat_levels then do;
            role = 'EXCLUDED';
            reason = cat('Text column with ', strip(put(n_dist, 8.)), ' distinct values (limit &sg_cfg_max_cat_levels) - would explode into bins');
        end;
        %if %length(&feature_cols) %then %do;
        else if indexw(upcase("&feature_cols"), upcase(nm), ' ') = 0 then do;
            role = 'EXCLUDED'; source = 'caller'; reason = 'Not in the caller feature_cols list';
        end;
        %end;
        else if not missing(leak_auc) and leak_auc >= &sg_cfg_leak_auc then do;
            role = 'EXCLUDED';
            reason = cat('Suspected target leakage: on its own this column separates defaults with |AUC-0.5| = ', strip(put(leak_auc, 5.3)));
        end;
        else if feat_rank > &sg_cfg_max_features and not missing(feat_rank) then do;
            role = 'EXCLUDED';
            reason = cat('Ranked ', strip(put(feat_rank, 5.)), ' of the usable columns by drift / default strength (|AUC-0.5| = ', strip(put(strength, 5.3)),
                          ') - only the top &sg_cfg_max_features are searched');
        end;
        else do;
            %if %length(&numeric_cols) or %length(&categorical_cols) %then %do;
            if lengthn(strip("&categorical_cols")) > 0 and indexw(upcase("&categorical_cols"), upcase(nm), ' ') > 0 then do;
                role = 'FEATURE_CATEGORICAL'; source = 'caller'; reason = 'Categorical feature (caller list)';
            end;
            else if lengthn(strip("&numeric_cols")) > 0 and indexw(upcase("&numeric_cols"), upcase(nm), ' ') > 0 then do;
                role = 'FEATURE_NUMERIC'; source = 'caller'; reason = 'Numeric feature (caller list)';
            end;
            else
            %end;
            if type = 2 then do;
                role = 'FEATURE_CATEGORICAL';
                reason = cat('Text column with ', strip(put(n_dist, 8.)), ' distinct values');
            end;
            else if n_dist <= &sg_cfg_cat_max_card then do;
                role = 'FEATURE_CATEGORICAL';
                reason = cat('Number with only ', strip(put(n_dist, 8.)), ' distinct values (<= &sg_cfg_cat_max_card) - treated as categorical');
            end;
            else do;
                role = 'FEATURE_NUMERIC';
                reason = cat('Number with ', strip(put(n_dist, 8.)), ' distinct values');
            end;
        end;
    run;

    /* ---- 8. lists for the engine ---- */
    proc sql noprint;
        select column_name into :sg_sc_features    separated by ' ' from &out where role in ('FEATURE_NUMERIC', 'FEATURE_CATEGORICAL') order by varnum;
        select column_name into :sg_sc_numeric     separated by ' ' from &out where role = 'FEATURE_NUMERIC' order by varnum;
        select column_name into :sg_sc_categorical separated by ' ' from &out where role = 'FEATURE_CATEGORICAL' order by varnum;
        select column_name into :sg_sc_shap        separated by ' ' from &out where role = 'SHAP' order by varnum;
        select column_name into :sg_sc_ids         separated by ' ' from &out where role = 'ID' order by varnum;
        select column_name into :sg_sc_time        separated by ' ' from &out where role = 'TIME' order by varnum;
    quit;

    %put NOTE: seg_detect_schema - target=&sg_sc_target score=&sg_sc_score weight=&sg_sc_weight;
    %put NOTE: seg_detect_schema - numeric features: &sg_sc_numeric;
    %put NOTE: seg_detect_schema - categorical features: &sg_sc_categorical;
    %put NOTE: seg_detect_schema - shap columns: &sg_sc_shap;
    %if not %length(&sg_sc_features) %then %do;
        %put ERROR: seg_detect_schema - no usable feature columns were found.;
        %let syscc = 8;
    %end;

%mend seg_detect_schema;
