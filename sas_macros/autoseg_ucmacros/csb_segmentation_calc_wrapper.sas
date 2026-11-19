/* ============================================================================
   csb_segmentation_calc_wrapper.sas
   Entry point for auto-segmentation (counterpart of csb_dq_dr_calc_wrapper) - the macro a
   Cirrus-triggered job calls. The TRIGGER ONLY NEEDS: the two tables and the target column.

       %csb_segmentation_calc_wrapper(dev_dta=lib.dev, mon_dta=lib.mon, target_col=default_flag);

   Everything else is decided by the module:
     * score / weight / ID / time / SHAP / feature columns -> seg_detect_schema (automatic)
     * technique parameters (depth, bins, beam, ...)        -> global defaults in seg_config and
       AUTO-OPTIMISED by grid search (sg_cfg_optimize = Y): the combination with the highest total
       Business_Impact_Score wins (K-Means and Gradient Boosting use fixed values for now)
     * limits and thresholds (top N, alpha, min events ...) -> global defaults in seg_config
   Optional arguments (all blank by default): techniques (default: all five), top_n, optimize (Y|N),
   exclude_cols, and explicit overrides score_col weight_col shap_cols feature_cols numeric_cols
   categorical_cols. Any seg_config setting can be overridden with %let sg_cfg_<name>=...; first.

   OUTPUT TABLES (prefix = out_prefix, default seg), all with column labels:
     per technique T (autoslicer drifttree gradboost kmeans featbin):
        seg_T_segments     top segments: rule, exact WHERE clause, plain-English summary, metrics
        seg_T_rules        exact conditions        seg_T_portfolio    significant top segments
        seg_T_feature_psi  drift of each feature inside each segment
        seg_T_pool         every evaluated candidate        seg_T_log   run facts
        seg_T_param_search every parameter combination tried, its score, and which one won
     seg_cross_top10 / seg_combined       ranking across techniques
     seg_schema            role + reason for EVERY column   seg_run_config   every setting used
     seg_run_log           status and time per technique    seg_metric_dictionary  what each column means
   ============================================================================ */
%macro csb_segmentation_calc_wrapper(dev_dta=, mon_dta=, target_col=, techniques=,
        score_col=, weight_col=, shap_cols=, feature_cols=, numeric_cols=, categorical_cols=,
        exclude_cols=, optimize=, top_n=, out_prefix=seg);

    %local i n t t0 status msg pfx prefixes opt tn xc dl bl nl keepc ncat ren cnv cln xv;

    %seg_config;

    %if not %length(&dev_dta) or not %length(&mon_dta) %then %do;
        %put ERROR: csb_segmentation_calc_wrapper - dev_dta= and mon_dta= are required.;
        %return;
    %end;

    %if not %length(&techniques) %then %let techniques = &sg_cfg_techniques;
    %if %length(&optimize) %then %let opt = %upcase(&optimize); %else %let opt = %upcase(&sg_cfg_optimize);
    %if %length(&top_n) %then %let tn = &top_n; %else %let tn = &sg_cfg_top_n;
    %if %length(&exclude_cols) %then %let xc = &exclude_cols; %else %let xc = &sg_cfg_exclude_cols;

    data &out_prefix._run_log;
        length technique $30 status $20 message $200 seconds 8;
        stop;
    run;

    /* ---- 1. automatic schema ---- */
    %let syscc = 0;
    %seg_detect_schema(dev=&dev_dta, mon=&mon_dta, target_col=&target_col, score_col=&score_col,
        weight_col=&weight_col, shap_cols=&shap_cols, feature_cols=&feature_cols,
        numeric_cols=&numeric_cols, categorical_cols=&categorical_cols, exclude_cols=&xc,
        out=&out_prefix._schema);
    %if &syscc > 4 %then %do;
        proc sql;
            insert into &out_prefix._run_log values("SCHEMA", "ERROR", "Schema detection failed - see log", 0);
        quit;
        %return;
    %end;

    /* ---- 1b. working copies: only the columns the engine needs (wide tables), and numbers that
           behave like categories (few distinct values) converted to text so every technique treats them alike ---- */
    %let keepc = &sg_sc_target &sg_sc_score &sg_sc_weight &sg_sc_shap &sg_sc_features;
    %let ncat = ;
    %let ren = ;
    %let cnv = ;
    %let cln = ;
    proc sql noprint;
        select column_name into :ncat separated by ' ' from &out_prefix._schema
        where role = 'FEATURE_CATEGORICAL' and data_type = 'numeric';
    quit;
    %do i = 1 %to %sysfunc(countw(&ncat, %str( )));
        %let xv = %scan(&ncat, &i, %str( ));
        %let ren = &ren &xv=_nc&i;
        %let cln = &cln length &xv $32%str(;);
        %let cnv = &cnv &xv = ifc(missing(_nc&i), '', strip(put(_nc&i, best12.)))%str(;);
    %end;
    data work._sgin_dev;
        &cln
        set &dev_dta(keep=&keepc %if %length(&ren) %then %do; rename=(&ren) %end;);
        &cnv
        %if %length(&ren) %then %do; drop _nc:; %end;
    run;
    data work._sgin_mon;
        &cln
        set &mon_dta(keep=&keepc %if %length(&ren) %then %do; rename=(&ren) %end;);
        &cnv
        %if %length(&ren) %then %do; drop _nc:; %end;
    run;
    %let dev_dta = work._sgin_dev;
    %let mon_dta = work._sgin_mon;

    %seg_cfg_log_add(setting=target_col, value=&sg_sc_target, source=%sysfunc(ifc(%length(&target_col), CALLER, AUTO)), desc=Default flag column);
    %seg_cfg_log_add(setting=score_col, value=&sg_sc_score, source=%sysfunc(ifc(%length(&score_col), CALLER, AUTO)), desc=Model score column);
    %seg_cfg_log_add(setting=weight_col, value=&sg_sc_weight, source=%sysfunc(ifc(%length(&weight_col), CALLER, AUTO)), desc=Exposure column);
    %seg_cfg_log_add(setting=numeric_features, value=&sg_sc_numeric, source=AUTO, desc=Numeric feature columns used);
    %seg_cfg_log_add(setting=categorical_features, value=&sg_sc_categorical, source=AUTO, desc=Categorical feature columns used);
    %seg_cfg_log_add(setting=shap_cols, value=&sg_sc_shap, source=AUTO, desc=SHAP columns used for the SHAP-shift diagnostic);
    %seg_cfg_log_add(setting=techniques, value=&techniques, source=%sysfunc(ifc(%length(&techniques), CALLER, DEFAULT)), desc=Techniques run);
    %seg_cfg_log_add(setting=optimize, value=&opt, source=RUN, desc=Whether technique parameters were chosen by grid search);

    /* ---- 2. techniques ---- */
    %let prefixes = ;
    %let n = %sysfunc(countw(&techniques, %str( )));
    %do i = 1 %to &n;
        %let t  = %upcase(%scan(&techniques, &i, %str( )));
        %let t0 = %sysfunc(datetime());
        %let status = OK;
        %let msg = ;
        %let syscc = 0;
        %let pfx = ;

        %if &t = AUTOSLICER %then %do;
            %let pfx = &out_prefix._autoslicer;
            %if &opt = Y %then %do; %let dl = &sg_cfg_as_depth_list; %let bl = &sg_cfg_as_beam_list; %let nl = &sg_cfg_as_bins_list; %end;
            %else %do; %let dl = &sg_cfg_as_depth; %let bl = &sg_cfg_as_beam; %let nl = &sg_cfg_as_bins; %end;
            %seg_autoslicer_grid(dev=&dev_dta, mon=&mon_dta, target_col=&sg_sc_target, score_col=&sg_sc_score,
                weight_col=&sg_sc_weight, feature_cols=&sg_sc_features, shap_cols=&sg_sc_shap,
                depth_list=&dl, beam_list=&bl, bins_list=&nl, min_beam_width=&sg_cfg_as_min_beam,
                beam_retain_ratio=&sg_cfg_as_retain, depth_improvement_tolerance=&sg_cfg_as_tol,
                top_n=&tn, min_events_per_slice=&sg_cfg_min_events, significance_alpha=&sg_cfg_alpha,
                max_segment_pct=&sg_cfg_max_segment_pct, overlap_jaccard_threshold=&sg_cfg_overlap,
                rca_name_filter=&sg_cfg_rca_name_filter, out_prefix=&pfx);
        %end;
        %else %if &t = DRIFT_TREE %then %do;
            %let pfx = &out_prefix._drifttree;
            %if &opt = Y %then %let dl = &sg_cfg_dt_depth_list; %else %let dl = &sg_cfg_dt_depth;
            %seg_drift_tree_grid(dev=&dev_dta, mon=&mon_dta, target_col=&sg_sc_target, score_col=&sg_sc_score,
                weight_col=&sg_sc_weight, feature_cols=&sg_sc_features, numeric_cols=&sg_sc_numeric,
                categorical_cols=&sg_sc_categorical, shap_cols=&sg_sc_shap, depth_list=&dl,
                min_samples_leaf=&sg_cfg_dt_min_leaf, top_n=&tn, min_events_per_slice=&sg_cfg_min_events,
                significance_alpha=&sg_cfg_alpha, max_segment_pct=&sg_cfg_max_segment_pct,
                rca_name_filter=&sg_cfg_rca_name_filter, out_prefix=&pfx);
        %end;
        %else %if &t = GRADIENT_BOOSTING %then %do;
            %let pfx = &out_prefix._gradboost;
            %seg_gradient_boosting(dev=&dev_dta, mon=&mon_dta, target_col=&sg_sc_target, score_col=&sg_sc_score,
                weight_col=&sg_sc_weight, numeric_cols=&sg_sc_numeric, categorical_cols=&sg_sc_categorical,
                shap_cols=&sg_sc_shap, n_estimators=&sg_cfg_gb_nest, max_depth=&sg_cfg_gb_depth,
                learning_rate=&sg_cfg_gb_lr, min_samples_leaf=&sg_cfg_gb_min_leaf, top_n=&tn,
                min_events_per_slice=&sg_cfg_min_events, significance_alpha=&sg_cfg_alpha,
                max_segment_pct=&sg_cfg_max_segment_pct, overlap_jaccard_threshold=&sg_cfg_overlap,
                rca_name_filter=&sg_cfg_rca_name_filter, out_prefix=&pfx);
            %seg_param_fixed(tech=Gradient Boosting, params=n_estimators=&sg_cfg_gb_nest max_depth=&sg_cfg_gb_depth, out=&pfx._param_search);
        %end;
        %else %if &t = KMEANS %then %do;
            %let pfx = &out_prefix._kmeans;
            %seg_kmeans(dev=&dev_dta, mon=&mon_dta, target_col=&sg_sc_target, score_col=&sg_sc_score,
                weight_col=&sg_sc_weight, feature_cols=&sg_sc_features, numeric_cols=&sg_sc_numeric,
                categorical_cols=&sg_sc_categorical, shap_cols=&sg_sc_shap, k_min=&sg_cfg_km_k_min,
                k_max=&sg_cfg_km_k_max, min_cluster_pct=&sg_cfg_km_min_cluster_pct, seed=&sg_cfg_km_seed,
                max_tree_depth=&sg_cfg_km_tree_depth, drift_aware=&sg_cfg_km_drift_aware,
                drift_weight=&sg_cfg_km_drift_weight, n_init=&sg_cfg_km_n_init, top_n=&tn,
                min_events_per_slice=&sg_cfg_min_events, significance_alpha=&sg_cfg_alpha,
                max_segment_pct=&sg_cfg_max_segment_pct, rca_name_filter=&sg_cfg_rca_name_filter, out_prefix=&pfx);
            %seg_param_fixed(tech=K-Means Clustering, params=drift_weight=&sg_cfg_km_drift_weight tree_depth=&sg_cfg_km_tree_depth, out=&pfx._param_search);
        %end;
        %else %if &t = FEATURE_BINNING %then %do;
            %let pfx = &out_prefix._featbin;
            %if &opt = Y %then %do; %let bl = &sg_cfg_fb_bins_list; %let nl = &sg_cfg_fb_minbin_list; %end;
            %else %do; %let bl = &sg_cfg_fb_max_bins; %let nl = &sg_cfg_fb_min_bin_pct; %end;
            %seg_feature_binning_grid(dev=&dev_dta, mon=&mon_dta, target_col=&sg_sc_target, score_col=&sg_sc_score,
                weight_col=&sg_sc_weight, feature_cols=&sg_sc_features, shap_cols=&sg_sc_shap,
                bins_list=&bl, minbin_list=&nl, max_features=&sg_cfg_fb_max_features,
                max_segment_pct=&sg_cfg_max_segment_pct, overlap_jaccard_threshold=&sg_cfg_overlap,
                top_n=&sg_cfg_fb_top_n, bootstrap_top_n=&sg_cfg_fb_bootstrap_top_n, n_iter=&sg_cfg_fb_n_iter,
                alpha=&sg_cfg_fb_alpha, seed=&sg_cfg_fb_seed, rca_name_filter=&sg_cfg_rca_name_filter,
                out_prefix=&pfx);
        %end;
        %else %do;
            %let status = NOT_RUN;
            %let msg = Unknown technique name;
            %put WARNING: csb_segmentation_calc_wrapper - unknown technique &t..;
        %end;

        %if &status = OK %then %do;
            %if &syscc > 4 %then %do;
                %let status = ERROR;
                %let msg = See log (SYSCC=&syscc);
            %end;
            %else %if %length(&pfx) %then %let prefixes = &prefixes &pfx;
        %end;

        proc sql;
            insert into &out_prefix._run_log
            values("&t", "&status", "&msg", %sysevalf(%sysfunc(datetime()) - &t0));
        quit;
    %end;

    /* ---- 3. cross-technique ranking ---- */
    %if %length(&prefixes) %then %do;
        %seg_cross_technique(prefixes=&prefixes, out_prefix=&out_prefix, top_n=10);
    %end;

    /* ---- 4. explainability: run config + data dictionary + column labels ---- */
    data &out_prefix._run_config; set _sg_cfg_log; run;
    %seg_metric_dictionary(out=&out_prefix._metric_dictionary);
    %seg_apply_labels(prefix=&out_prefix, dict=&out_prefix._metric_dictionary);

    %put NOTE: csb_segmentation_calc_wrapper complete - see &out_prefix._run_log and &out_prefix._schema;

%mend csb_segmentation_calc_wrapper;
