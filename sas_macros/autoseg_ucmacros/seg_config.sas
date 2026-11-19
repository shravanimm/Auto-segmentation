/* ============================================================================
   seg_config.sas
   GLOBAL DEFAULTS for the segmentation module - the trigger code only needs
   data + target (+ optionally the techniques); everything else lives here.

   Every setting is a global macro variable  sg_cfg_<name>.  A value that already
   exists and is non-blank is KEPT, so a caller (Cirrus job, test script) can
   override any default simply by  %let sg_cfg_<name> = ...;  BEFORE calling the
   wrapper. The effective value and where it came from (DEFAULT / OVERRIDE) are
   written to <prefix>_run_config, with a description, so a run is explainable.

   *_list settings  = candidate values that the AUTO-OPTIMISATION tries
                      (grid search, as the Streamlit "auto optimize" does);
                      the winner maximises the summed Business_Impact_Score of
                      the returned segments (core/parameter_optimization.py).
   fixed settings   = the single value used when sg_cfg_optimize = N.
   ============================================================================ */
%macro seg_cfg_set(name=, value=, desc=);
    %local src;
    %let src = DEFAULT;
    %if %symexist(&name) %then %do;
        %if %length(%superq(&name)) %then %do;
            /* a value left over from an earlier call in this session equals the default - only a different value is an override */
            %if "%superq(&name)" ne "%superq(value)" %then %let src = OVERRIDE;
        %end;
        %else %let &name = &value;
    %end;
    %else %do;
        %global &name;
        %let &name = &value;
    %end;
    data _sg_cfg_row;
        length setting $40 value $200 source $10 description $300;
        setting = "&name"; value = symget("&name"); source = "&src"; description = "&desc";
    run;
    proc append base=_sg_cfg_log data=_sg_cfg_row force; run;
%mend seg_cfg_set;

%macro seg_cfg_log_add(setting=, value=, source=, desc=);
    data _sg_cfg_row;
        length setting $40 value $200 source $10 description $300;
        setting = "&setting"; value = "&value"; source = "&source"; description = "&desc";
    run;
    proc append base=_sg_cfg_log data=_sg_cfg_row force; run;
%mend seg_cfg_log_add;

%macro seg_param_fixed(tech=, params=, out=);
    /* techniques without a grid search yet: record the fixed values that were used */
    data &out;
        length technique $30 combo 8 parameters $300 objective_score 8 rank_by_score 8 selected 8 selection_rule $200;
        technique = "&tech"; combo = 1; parameters = "&params"; objective_score = .; rank_by_score = 1; selected = 1;
        selection_rule = 'Fixed global defaults - automatic parameter search is not enabled for this technique yet';
    run;
%mend seg_param_fixed;

%macro seg_config;

    proc datasets lib=work nolist nowarn; delete _sg_cfg_log; quit;

    /* ---- run control ---- */
    %seg_cfg_set(name=sg_cfg_techniques, value=AUTOSLICER DRIFT_TREE GRADIENT_BOOSTING KMEANS FEATURE_BINNING,
                 desc=Techniques to run when the trigger does not name any);
    %seg_cfg_set(name=sg_cfg_optimize, value=Y,
                 desc=Y = choose technique parameters automatically by grid search - N = use the fixed values below);
    %seg_cfg_set(name=sg_cfg_top_n, value=10, desc=Segments returned per technique);
    %seg_cfg_set(name=sg_cfg_min_events, value=30,
                 desc=Minimum defaults (events) required in a segment on BOTH dev and monitoring side);
    %seg_cfg_set(name=sg_cfg_alpha, value=0.05,
                 desc=Significance level after Benjamini-Hochberg multiple-testing correction);
    %seg_cfg_set(name=sg_cfg_max_segment_pct, value=0.35,
                 desc=Largest allowed segment as a share of the population - broader segments are not informative);
    %seg_cfg_set(name=sg_cfg_overlap, value=0.70,
                 desc=Jaccard overlap above which a segment is dropped as a near-duplicate of a better one);
    %seg_cfg_set(name=sg_cfg_rca_name_filter, value=Y,
                 desc=Y = exclude ID/time/SHAP-looking names from the in-segment root-cause feature list);

    /* ---- schema auto-detection ---- */
    %seg_cfg_set(name=sg_cfg_exclude_cols, value=,
                 desc=Columns the caller never wants used as features (space separated));
    %seg_cfg_set(name=sg_cfg_cat_max_card, value=20,
                 desc=A numeric column with at most this many distinct values is treated as categorical);
    %seg_cfg_set(name=sg_cfg_id_uniq, value=0.98,
                 desc=A text or integer column unique in more than this share of rows is treated as an identifier);
    %seg_cfg_set(name=sg_cfg_leak_auc, value=0.45,
                 desc=A numeric feature whose single-feature |AUC-0.5| reaches this is dropped as suspected target leakage (1 = off));
    %seg_cfg_set(name=sg_cfg_max_features, value=30,
                 desc=Wide tables - only this many strongest columns by drift and default strength are searched);
    %seg_cfg_set(name=sg_cfg_max_cat_levels, value=50,
                 desc=A text feature with more distinct values than this is dropped (one-hot / bin explosion));

    /* ---- AutoSlicer ---- */
    %seg_cfg_set(name=sg_cfg_as_depth_list, value=2 3 4, desc=AutoSlicer: maximum number of conditions per segment - values tried);
    %seg_cfg_set(name=sg_cfg_as_beam_list, value=10 20 30, desc=AutoSlicer: beam width (candidates kept per level) - values tried);
    %seg_cfg_set(name=sg_cfg_as_bins_list, value=3 4 6, desc=AutoSlicer: quantile bins per numeric feature - values tried);
    %seg_cfg_set(name=sg_cfg_as_depth, value=3, desc=AutoSlicer: fixed depth when optimisation is off);
    %seg_cfg_set(name=sg_cfg_as_beam, value=20, desc=AutoSlicer: fixed beam width when optimisation is off);
    %seg_cfg_set(name=sg_cfg_as_bins, value=4, desc=AutoSlicer: fixed numeric bins when optimisation is off);
    %seg_cfg_set(name=sg_cfg_as_min_beam, value=8, desc=AutoSlicer: minimum beam kept after pruning);
    %seg_cfg_set(name=sg_cfg_as_retain, value=0.5, desc=AutoSlicer: keep beam rows scoring at least this share of the best);
    %seg_cfg_set(name=sg_cfg_as_tol, value=0.05, desc=AutoSlicer: stop deepening when the best score improves by less than this);

    /* ---- Drift Localization Tree ---- */
    %seg_cfg_set(name=sg_cfg_dt_depth_list, value=2 3 4, desc=Drift Tree: tree depth - values tried);
    %seg_cfg_set(name=sg_cfg_dt_depth, value=3, desc=Drift Tree: fixed depth when optimisation is off);
    %seg_cfg_set(name=sg_cfg_dt_min_leaf, value=0.05, desc=Drift Tree: minimum leaf size as a share of all rows);

    /* ---- Gradient Boosting (grid search arrives in the next drop; fixed values are used) ---- */
    %seg_cfg_set(name=sg_cfg_gb_depth_list, value=2 3 4, desc=Gradient Boosting: tree depth - values to try);
    %seg_cfg_set(name=sg_cfg_gb_nest_list, value=50 100 150, desc=Gradient Boosting: number of trees - values to try);
    %seg_cfg_set(name=sg_cfg_gb_depth, value=3, desc=Gradient Boosting: tree depth used);
    %seg_cfg_set(name=sg_cfg_gb_nest, value=100, desc=Gradient Boosting: number of trees used);
    %seg_cfg_set(name=sg_cfg_gb_lr, value=0.1, desc=Gradient Boosting: learning rate);
    %seg_cfg_set(name=sg_cfg_gb_min_leaf, value=0.05, desc=Gradient Boosting: minimum leaf size as a share of all rows);

    /* ---- K-Means (grid search arrives in the next drop; fixed values are used) ---- */
    %seg_cfg_set(name=sg_cfg_km_k_min, value=2, desc=K-Means: smallest number of clusters considered);
    %seg_cfg_set(name=sg_cfg_km_k_max, value=12, desc=K-Means: largest number of clusters considered);
    %seg_cfg_set(name=sg_cfg_km_min_cluster_pct, value=0.03, desc=K-Means: a k is rejected if its smallest cluster is below this share);
    %seg_cfg_set(name=sg_cfg_km_seed, value=42, desc=K-Means: random seed);
    %seg_cfg_set(name=sg_cfg_km_n_init, value=10, desc=K-Means: random restarts per k - the best fit is kept);
    %seg_cfg_set(name=sg_cfg_km_drift_aware, value=Y, desc=K-Means: Y = monitoring drift also influences the choice of k);
    %seg_cfg_set(name=sg_cfg_km_drift_weight_list, value=0.2 0.4 0.6, desc=K-Means: drift weight in the k choice - values to try);
    %seg_cfg_set(name=sg_cfg_km_tree_depth_list, value=3 4 5, desc=K-Means: depth of the rule-explanation tree - values to try);
    %seg_cfg_set(name=sg_cfg_km_drift_weight, value=0.4, desc=K-Means: drift weight used);
    %seg_cfg_set(name=sg_cfg_km_tree_depth, value=4, desc=K-Means: depth of the rule-explanation tree used);

    /* ---- Feature Binning ---- */
    %seg_cfg_set(name=sg_cfg_fb_bins_list, value=5 8 10 12, desc=Feature Binning: maximum bins per feature - values tried);
    %seg_cfg_set(name=sg_cfg_fb_minbin_list, value=0.01 0.02 0.03, desc=Feature Binning: smallest allowed bin as a share of rows - values tried);
    %seg_cfg_set(name=sg_cfg_fb_max_bins, value=8, desc=Feature Binning: fixed maximum bins when optimisation is off);
    %seg_cfg_set(name=sg_cfg_fb_min_bin_pct, value=0.01, desc=Feature Binning: fixed smallest bin share when optimisation is off);
    %seg_cfg_set(name=sg_cfg_fb_max_features, value=30, desc=Feature Binning: strongest features that get binned);
    %seg_cfg_set(name=sg_cfg_fb_top_n, value=20, desc=Feature Binning: segments returned);
    %seg_cfg_set(name=sg_cfg_fb_bootstrap_top_n, value=40, desc=Feature Binning: candidates that receive bootstrap significance tests);
    %seg_cfg_set(name=sg_cfg_fb_n_iter, value=50, desc=Feature Binning: bootstrap resamples per candidate);
    %seg_cfg_set(name=sg_cfg_fb_alpha, value=0.10, desc=Feature Binning: significance level for its bootstrap tests);
    %seg_cfg_set(name=sg_cfg_fb_seed, value=42, desc=Feature Binning: bootstrap random seed);

    /* ---- Trend analysis over several monitoring periods ---- */
    %seg_cfg_set(name=sg_cfg_tr_n_worst, value=10, desc=Trend: a segment appears in a period when it is among the worst N of its technique);
    %seg_cfg_set(name=sg_cfg_tr_half_life, value=2, desc=Trend: recency half-life in periods - recency halves for every this many periods since the last appearance);
    %seg_cfg_set(name=sg_cfg_tr_w_freq, value=0.4, desc=Trend: weight of frequency in the Trend Impact Score);
    %seg_cfg_set(name=sg_cfg_tr_w_rec, value=0.3, desc=Trend: weight of recency in the Trend Impact Score);
    %seg_cfg_set(name=sg_cfg_tr_w_cons, value=0.3, desc=Trend: weight of consistency in the Trend Impact Score);
    %seg_cfg_set(name=sg_cfg_tr_weight, value=0.5, desc=Trend: how strongly persistence boosts the root-cause score);
    %seg_cfg_set(name=sg_cfg_tr_alert, value=0.5, desc=Trend: early warning when the projected root-cause score will cross this level);
    %seg_cfg_set(name=sg_cfg_tr_horizon, value=6, desc=Trend: early warning looks this many periods ahead);

%mend seg_config;
