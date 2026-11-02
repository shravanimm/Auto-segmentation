/* ============================================================================
   seg_fb_score.sas
   Feature Binning's own scoring (techniques/feature_binning.score_segments).
   Differs from the shared seg_score_candidates:
     * significance = Benjamini-Hochberg over the five BOOTSTRAP p-values
       (gini, ks, auc, br, ece); significant = smallest adjusted p <= alpha;
       confidence = mean(1 - adjusted p)  (unadjusted pool: 0.5 / not significant)
     * Business_Impact_Score = exposure share clipped to [0,1]
     * deterioration_score = mean of the min-max normalised gini/ks/auc drops,
       |bad-rate shift| and |ECE shift| (diagnostic / tie-break only)
     * SIS, DIS and Root_Cause_Score use the same formulas as the shared engine
       but are normalised WITHIN THE POOL passed in.
   FB's deltas are dev - mon (positive = worse); the shared engine's are
   mon - dev, so fb_delta = -delta for gini/ks/auc.
   KNOWN PROPERTY OF THE PYTHON CODE (ported faithfully): the bootstrapped
   candidates and the remainder are scored by two SEPARATE calls, so their
   normalised scores are not on a common scale yet get ranked together.
   in  : cand_id + engine metrics (n_dev ... mean_shap_shift, delta_br,
         delta_ece, mon_weight_pct) + gini_p ks_p auc_p br_p ece_p
   out : in + fb_delta_*, deterioration_score, confidence_score, min_p_adj,
         significant, sis_raw, dis_raw, business_impact_score, psi_interpretation,
         root_cause_score_raw, final_score
   ============================================================================ */
%macro seg_fb_score(in=, out=, apply_bh=Y, alpha=0.10);

    %local m nmx;

    data _fs_a;
        set &in;
        fb_delta_gini = ifn(missing(delta_gini), ., -delta_gini);
        fb_delta_ks   = ifn(missing(delta_ks),   ., -delta_ks);
        fb_delta_auc  = ifn(missing(delta_auc),  ., -delta_auc);
        abs_delta_br  = abs(delta_br);
        abs_delta_ece = abs(delta_ece);
        auc_drop = ifn(missing(fb_delta_auc), 0, max(0, fb_delta_auc));
        conf     = min(1, sqrt(max(0, n_mon) / 100));
        ef       = ifn(mon_weight_pct > 0, mon_weight_pct, 1);
        sis_raw  = auc_drop * ef * pct_mon * conf;
        dis_raw  = max(0, (pct_mon - pct_dev) * auc_drop * ef * (1 + max(0, mean_feature_psi)));
        business_impact_score = min(max(coalesce(mon_weight_pct, 0), 0), 1);
    run;

    proc sql noprint;
        select min(fb_delta_gini) format=best32., max(fb_delta_gini) format=best32., min(fb_delta_ks) format=best32., max(fb_delta_ks) format=best32.,
               min(fb_delta_auc) format=best32., max(fb_delta_auc) format=best32., min(abs_delta_br) format=best32., max(abs_delta_br) format=best32.,
               min(abs_delta_ece) format=best32., max(abs_delta_ece) format=best32., min(sis_raw) format=best32., max(sis_raw) format=best32.,
               min(dis_raw) format=best32., max(dis_raw) format=best32., min(mean_feature_psi) format=best32., max(mean_feature_psi) format=best32.,
               min(mean_shap_shift) format=best32., max(mean_shap_shift) format=best32.
          into :g_lo trimmed, :g_hi trimmed, :k_lo trimmed, :k_hi trimmed, :a_lo trimmed, :a_hi trimmed,
               :b_lo trimmed, :b_hi trimmed, :e_lo trimmed, :e_hi trimmed, :s_lo trimmed, :s_hi trimmed,
               :d_lo trimmed, :d_hi trimmed, :p_lo trimmed, :p_hi trimmed, :h_lo trimmed, :h_hi trimmed
          from _fs_a;
    quit;

    %if %upcase(&apply_bh) = Y %then %do;
        %seg_bh(in=_fs_a, pvar=gini_p, adjvar=gini_padj, out=_fs_b1);
        %seg_bh(in=_fs_a, pvar=ks_p,   adjvar=ks_padj,   out=_fs_b2);
        %seg_bh(in=_fs_a, pvar=auc_p,  adjvar=auc_padj,  out=_fs_b3);
        %seg_bh(in=_fs_a, pvar=br_p,   adjvar=br_padj,   out=_fs_b4);
        %seg_bh(in=_fs_a, pvar=ece_p,  adjvar=ece_padj,  out=_fs_b5);
        proc sort data=_fs_a; by cand_id; run;
        data _fs_a;
            merge _fs_a _fs_b1 _fs_b2 _fs_b3 _fs_b4 _fs_b5;
            by cand_id;
        run;
    %end;

    data &out;
        set _fs_a;
        length psi_interpretation $20;
        /* normalise: zeros if range < 1e-9, NaN stays NaN */
        if &g_hi - &g_lo < 1e-9 then _gs = 0; else _gs = (fb_delta_gini - &g_lo) / (&g_hi - &g_lo);
        if &k_hi - &k_lo < 1e-9 then _ks = 0; else _ks = (fb_delta_ks   - &k_lo) / (&k_hi - &k_lo);
        if &a_hi - &a_lo < 1e-9 then _as = 0; else _as = (fb_delta_auc  - &a_lo) / (&a_hi - &a_lo);
        if &b_hi - &b_lo < 1e-9 then _bs = 0; else _bs = (abs_delta_br  - &b_lo) / (&b_hi - &b_lo);
        if &e_hi - &e_lo < 1e-9 then _es = 0; else _es = (abs_delta_ece - &e_lo) / (&e_hi - &e_lo);
        deterioration_score = mean(_gs, _ks, _as, _bs, _es);

        %if %upcase(&apply_bh) = Y %then %do;
            min_p_adj = min(gini_padj, ks_padj, auc_padj, br_padj, ece_padj);
            confidence_score = mean(1 - min(max(coalesce(gini_padj, 1), 0), 1),
                                    1 - min(max(coalesce(ks_padj,   1), 0), 1),
                                    1 - min(max(coalesce(auc_padj,  1), 0), 1),
                                    1 - min(max(coalesce(br_padj,   1), 0), 1),
                                    1 - min(max(coalesce(ece_padj,  1), 0), 1));
            significant = (not missing(min_p_adj)) and (min_p_adj <= &alpha);
        %end;
        %else %do;
            min_p_adj = .; confidence_score = 0.5; significant = 0;
        %end;

        if psi < 0.1 then psi_interpretation = 'Stable';
        else if psi <= 0.25 then psi_interpretation = 'Moderate Drift';
        else psi_interpretation = 'Significant Drift';

        if &s_hi - &s_lo < 1e-9 then _n1 = 0; else _n1 = (sis_raw - &s_lo) / (&s_hi - &s_lo);
        if &d_hi - &d_lo < 1e-9 then _n2 = 0; else _n2 = (dis_raw - &d_lo) / (&d_hi - &d_lo);
        if &p_hi - &p_lo < 1e-9 then _n3 = 0; else _n3 = (mean_feature_psi - &p_lo) / (&p_hi - &p_lo);
        if &h_hi - &h_lo < 1e-9 then _n4 = 0; else _n4 = (mean_shap_shift - &h_lo) / (&h_hi - &h_lo);
        root_cause_score_raw = 0.35 * _n1 + 0.30 * _n2 + 0.20 * _n3 + 0.15 * _n4;
        final_score = root_cause_score_raw * 20;
        drop _gs _ks _as _bs _es _n1-_n4 auc_drop conf ef;
    run;

%mend seg_fb_score;
