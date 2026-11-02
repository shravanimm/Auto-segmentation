/* ============================================================================
   seg_prep.sas
   Shared by every segmentation technique. Builds the two working tables the
   engine reads and derives the population-level thresholds.

   Creates (WORK):
     _sg_dev / _sg_mon : _rid (row id), _y (target 0/1), _s (model score),
                         _w (exposure; 0 when no weight_col), plus the feature
                         columns and shap columns passed in.
   Creates (global macro vars):
     sg_ndev sg_nmon        row counts
     sg_twdev sg_twmon      total exposure (0 when no weight_col)
     sg_rate                dev event rate
     sg_minabs sg_minsup    derived support gates (core/candidate_filtering.py)
     sg_maxpct sg_minev     max segment share / min events per slice
     sg_nf                  number of features
     sg_rca_feats           features used for in-segment root-cause PSI

   Missing model scores: rows are kept (as in Python) but AUC/KS need non-
   missing scores - a NOTE is written when any are found.
   ============================================================================ */
%macro seg_prep(dev=, mon=, target_col=, score_col=, weight_col=, feature_cols=, shap_cols=,
                min_abs_count=, min_support=, min_events_per_slice=30, max_segment_pct=0.35,
                rca_name_filter=Y);

    %global sg_ndev sg_nmon sg_twdev sg_twmon sg_rate sg_minabs sg_minsup sg_maxpct sg_minev
            sg_nf sg_rca_feats sg_premem;
    %local i f keep _sg_bad _sg_nmiss_d _sg_nmiss_m;

    /* sg_premem = Y : candidates' row membership is supplied in _sg_memb_dev /
       _sg_memb_mon (cand_id,_rid) by the technique (tree leaves, clusters, bins)
       instead of being derived from predicate vectors c1..cN (AutoSlicer). */
    %let sg_premem = N;

    %let sg_nf     = %sysfunc(countw(&feature_cols, %str( )));
    %let sg_maxpct = &max_segment_pct;
    %let sg_minev  = &min_events_per_slice;

    data _sg_dev;
        set &dev(keep=&target_col &score_col &weight_col &feature_cols &shap_cols);
        _rid = _n_;
        _y   = &target_col;
        _s   = &score_col;
        %if %length(&weight_col) %then %do; _w = &weight_col; %end;
        %else %do; _w = 0; %end;
    run;

    data _sg_mon;
        set &mon(keep=&target_col &score_col &weight_col &feature_cols &shap_cols);
        _rid = _n_;
        _y   = &target_col;
        _s   = &score_col;
        %if %length(&weight_col) %then %do; _w = &weight_col; %end;
        %else %do; _w = 0; %end;
    run;

    proc sql noprint;
        select count(*), sum(_w) format=best32., mean(_y) format=best32., nmiss(_s)
          into :sg_ndev trimmed, :sg_twdev trimmed, :sg_rate trimmed, :_sg_nmiss_d trimmed
          from _sg_dev;
        select count(*), sum(_w) format=best32., nmiss(_s)
          into :sg_nmon trimmed, :sg_twmon trimmed, :_sg_nmiss_m trimmed
          from _sg_mon;
    quit;
    %if %sysevalf(&_sg_nmiss_d + &_sg_nmiss_m > 0) %then
        %put NOTE: seg_prep - missing model scores found - AUC/KS are undefined for those rows.;

    /* derive_min_abs_count / derive_min_support (core/candidate_filtering.py) */
    data _null_;
        rate = &sg_rate;
        %if %length(&min_abs_count) %then %do; minabs = &min_abs_count; %end;
        %else %do; minabs = max(50, ceil(&min_events_per_slice / max(rate, 1e-4))); %end;
        %if %length(&min_support) %then %do; minsup = &min_support; %end;
        %else %do; minsup = min(0.30, max(0.02, minabs / min(&sg_ndev, &sg_nmon))); %end;
        call symputx('sg_minabs', minabs, 'G');
        call symputx('sg_minsup', put(minsup, best32.), 'G');
    run;

    /* Root-cause feature list = feature_cols minus ID/time/shap-looking names,
       as core/candidate_evaluation._sanitize_feature_columns does.
       NOTE: that Python filter is an UNANCHORED substring match, so e.g.
       "months_on_book" is dropped from root-cause analysis. rca_name_filter=N
       disables it (documented deviation switch). */
    %let sg_rca_feats = ;
    %do i = 1 %to &sg_nf;
        %let f    = %scan(&feature_cols, &i, %str( ));
        %let keep = 1;
        %if %upcase(&rca_name_filter) = Y %then %do;
            data _null_;
                length nm $64;
                nm  = "&f";
                bad = prxmatch('/(^id$|_id$|^id_|customer_?id|account_?id|application_?id|loan_?id|transaction_?id|uuid|identifier)/i', strip(nm)) > 0
                   or prxmatch('/(month|period|date|vintage|snapshot|as_of|year|timestamp)/i', strip(nm)) > 0
                   or prxmatch('/^shap[_\-]/i', strip(nm)) > 0;
                call symputx('_sg_bad', bad, 'L');
            run;
            %if &_sg_bad %then %let keep = 0;
        %end;
        %if %upcase(&f) = %upcase(&target_col) or %upcase(&f) = %upcase(&score_col) %then %let keep = 0;
        %if %length(&weight_col) %then %do;
            %if %upcase(&f) = %upcase(&weight_col) %then %let keep = 0;
        %end;
        %if &keep %then %let sg_rca_feats = &sg_rca_feats &f;
    %end;
    %let sg_rca_feats = %sysfunc(strip(&sg_rca_feats));

    %put NOTE: seg_prep - ndev=&sg_ndev nmon=&sg_nmon min_abs_count=&sg_minabs min_support=&sg_minsup;
    %put NOTE: seg_prep - root-cause features: &sg_rca_feats;

%mend seg_prep;
