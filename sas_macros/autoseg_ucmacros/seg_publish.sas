/* ============================================================================
   seg_publish.sas
   Shared tail of AutoSlicer / Drift Tree / Gradient Boosting / K-Means:
   score the whole evaluated pool (seg_score_candidates), significance-first
   rank, optional Jaccard de-dup, keep top_n, and write the public tables.

   Reads : _sg_pool _sg_memmon_all _sg_rules_all _sg_fpsi_all (may not exist =
           no candidate survived)
   Writes: &out_prefix._segments _rules _portfolio _feature_psi _pool _log
   dedup : Y (AutoSlicer, Gradient Boosting) | N (Drift Tree, K-Means)
   dropvars : internal columns to drop from the public segments table
   Column names follow the Python public output (Dev_Count ... Root_Cause_Score).
   ============================================================================ */
%macro seg_publish(technique=, out_prefix=, top_n=10, dedup=Y, overlap=0.70, pool_size=30,
                   alpha=0.05, dropvars=, portfolio_n=);

    %if not %length(&portfolio_n) %then %let portfolio_n = &top_n;

    %if not %sysfunc(exist(_sg_pool)) %then %do;
        %put NOTE: seg_publish - &technique produced no candidates.;
        data &out_prefix._segments; length Technique $40 Rank 8 Segment_Definition $1000; stop; run;
        data &out_prefix._rules;    length Rank 8 cand_id 8 feature $64; stop; run;
        data &out_prefix._portfolio; length Rank 8 Segment $1000; stop; run;
        data &out_prefix._feature_psi; length Rank 8 cand_id 8 feature $64 psi 8; stop; run;
        data &out_prefix._pool; length cand_id 8 Segment_Definition $1000; stop; run;
    %end;
    %else %do;
        %seg_score_candidates(in=_sg_pool, out=_sg_scored, alpha=&alpha);
        %seg_rank_dedup(in=_sg_scored, mem_mon=_sg_memmon_all, out=_sg_dd,
                        overlap=&overlap, pool_size=&pool_size, dedup=&dedup);

        data _sg_top;
            length Technique $40;
            set _sg_dd(obs=&top_n);
            Rank = dedup_rank;
            Technique = "&technique";
        run;

        data &out_prefix._pool; set _sg_scored; run;

        data &out_prefix._segments;
            length Technique $40 Rank 8 Segment_Definition $1000;
            set _sg_top(drop=dedup_rank &dropvars
                        rename=(n_dev=Dev_Count n_mon=Mon_Count pct_dev=Dev_Pct pct_mon=Mon_Pct
                                br_dev=Dev_BR br_mon=Mon_BR
                                auc_dev=Dev_AUC auc_mon=Mon_AUC
                                gini_dev=Dev_Gini gini_mon=Mon_Gini
                                ks_dev=Dev_KS ks_mon=Mon_KS
                                weight_dev=Dev_EAD weight_mon=Mon_EAD
                                dev_weight_pct=Dev_Exposure_Pct mon_weight_pct=Mon_Exposure_Pct
                                exposure_drift=Exposure_Drift calibration_drift=Calibration_Drift
                                top_drift_feature=Root_Cause_Feature top_drift_psi=Root_Cause_PSI
                                root_cause_score=Root_Cause_Score));
        run;

        /* case-only renames (SAS names are case-insensitive) */
        %seg_fix_case(ds=&out_prefix._segments, names=PSI Delta_BR Delta_AUC Delta_Gini Delta_KS);

        proc sql;
            create table &out_prefix._rules as
            select t.Rank, t.cand_id, r.feature, r.ptype, r.lower, r.upper, r.lo_inf, r.hi_inf,
                   r.value, r.label
            from _sg_top t inner join _sg_rules_all r on t.cand_id = r.cand_id
            order by t.Rank, r.feat_idx;

            create table &out_prefix._feature_psi as
            select t.Rank, f.cand_id, f.feature, f.psi
            from _sg_top t inner join _sg_fpsi_all f on t.cand_id = f.cand_id
            order by t.Rank, f.feat_idx;
        quit;

        proc sort data=_sg_top(where=(Statistically_Significant = 1)) out=_sg_pf;
            by descending Portfolio_Impact_Score cand_id;
        run;
        data &out_prefix._portfolio;
            set _sg_pf(obs=&portfolio_n);
            Rank = _n_;
            Segment = Segment_Definition;
            Population_Pct = pct_mon;
            Severity_PopulationXGini = Portfolio_Impact_Score;
            Delta_Gini = delta_gini;
            Delta_KS   = delta_ks;
            Delta_BR   = delta_br;
            keep Rank Segment Population_Pct Delta_Gini Delta_KS Delta_BR Severity_PopulationXGini
                 SIS_Raw Statistically_Significant;
        run;
    %end;

    data &out_prefix._log;
        technique            = "&technique";
        total_dev_n          = &sg_ndev;
        total_mon_n          = &sg_nmon;
        min_abs_count        = &sg_minabs;
        min_support          = &sg_minsup;
        candidates_evaluated = %seg_nobs(&out_prefix._pool);
        candidates_returned  = %seg_nobs(&out_prefix._segments);
        run_datetime         = datetime();
        format run_datetime datetime20.;
    run;

%mend seg_publish;
