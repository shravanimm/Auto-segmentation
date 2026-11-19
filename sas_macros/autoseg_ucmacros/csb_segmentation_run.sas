/* ============================================================================
   csb_segmentation_run.sas
   ONE ENTRY POINT - the same flow as the Streamlit "Compare All Segmentation Techniques" tab:

     1. Run trend analysis?            trend = N (default) | Y
     2. Which techniques?              techniques = AUTOSLICER DRIFT_TREE GRADIENT_BOOSTING KMEANS FEATURE_BINNING
                                       (blank = all five, or the global sg_cfg_techniques)
   The chosen techniques run, then the cross-technique ranking is built from them.

   trend = N  : single comparison, development vs the monitoring table
                -> csb_segmentation_calc_wrapper    outputs  seg_*   (seg_cross_top10 ...)
   trend = Y  : mon_dta holds several periods (period_col); the techniques run once per period,
                recurring segments get Frequency / Recency / Consistency / Trend_Impact_Score,
                techniques are ranked on the trend-boosted scores, plus forecast + early warning
                -> csb_segmentation_trend_wrapper   outputs  segtr_*  (segtr_cross_top10 ...)

   MINIMUM TRIGGER
       %csb_segmentation_run(dev_dta=work.dev, mon_dta=work.mon, target_col=default_flag);
       %csb_segmentation_run(dev_dta=work.dev, mon_dta=work.mon_all, target_col=default_flag,
                             trend=Y, period_col=month, techniques=AUTOSLICER FEATURE_BINNING);
   Everything else (score / weight / SHAP / feature columns, every technique parameter) is
   detected, defaulted by the global sg_cfg_* variables or auto-optimised - see seg_config.sas.
   ============================================================================ */
%macro csb_segmentation_run(dev_dta=, mon_dta=, target_col=, trend=N, period_col=, techniques=,
        score_col=, weight_col=, shap_cols=, feature_cols=, numeric_cols=, categorical_cols=,
        exclude_cols=, optimize=, top_n=, out_prefix=);

    %local tr op;
    %let tr = N;
    %if %length(&trend) %then %let tr = %upcase(%substr(&trend, 1, 1));

    %if &tr = Y %then %do;
        %if not %length(&period_col) %then %do;
            %put ERROR: csb_segmentation_run - trend=Y needs period_col= (the period column of mon_dta).;
            %return;
        %end;
        %if %length(&out_prefix) %then %let op = &out_prefix; %else %let op = segtr;
        %put NOTE: csb_segmentation_run - TREND ANALYSIS = Y, periods from &period_col, outputs &op._*;
        %csb_segmentation_trend_wrapper(dev_dta=&dev_dta, mon_dta=&mon_dta, period_col=&period_col,
            target_col=&target_col, techniques=&techniques, score_col=&score_col, weight_col=&weight_col,
            shap_cols=&shap_cols, feature_cols=&feature_cols, numeric_cols=&numeric_cols,
            categorical_cols=&categorical_cols, exclude_cols=&exclude_cols, optimize=&optimize,
            top_n=&top_n, out_prefix=&op);
    %end;
    %else %do;
        %if %length(&out_prefix) %then %let op = &out_prefix; %else %let op = seg;
        %put NOTE: csb_segmentation_run - TREND ANALYSIS = N, single comparison, outputs &op._*;
        %csb_segmentation_calc_wrapper(dev_dta=&dev_dta, mon_dta=&mon_dta, target_col=&target_col,
            techniques=&techniques, score_col=&score_col, weight_col=&weight_col, shap_cols=&shap_cols,
            feature_cols=&feature_cols, numeric_cols=&numeric_cols, categorical_cols=&categorical_cols,
            exclude_cols=&exclude_cols, optimize=&optimize, top_n=&top_n, out_prefix=&op);
    %end;

%mend csb_segmentation_run;
