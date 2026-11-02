/* ============================================================================
   seg_km_select_k.sas
   Port of techniques/kmeans.select_optimal_k. For each k in [k_min, k_max]
   (k >= 2, k < n):
     * fit with the configured seed; reject k if its smallest cluster is below
       min_cluster_pct of the dev rows
     * stability = adjusted Rand index vs a second fit with seed 777
     * silhouette, Calinski-Harabasz, Davies-Bouldin on the first fit
     * max relative cluster drift = max_c |mon_share_c - dev_share_c| /
       max(dev_share_c, 1e-6), monitoring assigned to the dev centres
   Scores (over the accepted k): min-max normalise each metric (constant column
   -> 1.0), internal = mean(sil_n, ch_n, 1 - db_n);
     drift_aware : composite = (1-w)*(0.5*internal + 0.5*stab_n) + w*drift_n
     otherwise   : composite =  0.5*internal + 0.5*stab_n
   best k = first maximum. NOTE (design property carried over from Python): in
   the drift-aware mode monitoring data influences the choice of k, and the
   relative-drift term tends to grow with k.
   Needs _km_xd / _km_xm. Leaves for every k: _km_la<k> _km_ca<k> (fit A).
   Outputs: _km_diag (diagnostics) and global sg_km_bestk.
   ============================================================================ */
%macro seg_km_select_k(k_min=, k_max=, min_cluster_pct=, seed=, drift_aware=Y, drift_weight=0.4,
                       n_init=10, d=, n=, nmon=);

    %global sg_km_bestk;
    %local k ngrp minfrac ari sil ch db drift s_lo s_hi c_lo c_hi d_lo d_hi t_lo t_hi m_lo m_hi sij sa sb;

    data _km_diag;
        length k 8 silhouette 8 calinski_harabasz 8 davies_bouldin 8 stability_ari 8
               max_cluster_drift 8 min_cluster_pct 8 composite 8 rejected_reason $100;
        stop;
    run;

    %do k = &k_min %to &k_max;
      %if &k >= 2 and &k < &n %then %do;

        %seg_km_fit(data=_km_xd, n=&n, d=&d, k=&k, seed=&seed, n_init=&n_init,
                    out_lab=_km_la&k, out_cen=_km_ca&k);

        proc sql noprint;
            create table _km_sz as select lab, count(*) as cnt from _km_la&k group by lab;
            select count(*), min(cnt) / &n format=best32. into :ngrp trimmed, :minfrac trimmed from _km_sz;
        quit;
        %if &ngrp < &k %then %let minfrac = 0;

        %if %sysevalf(&minfrac < &min_cluster_pct) %then %do;
            data _km_row;
                k = &k; min_cluster_pct = &minfrac; composite = .;
                length rejected_reason $100;
                rejected_reason = cats('smallest cluster ', put(100 * &minfrac, 8.1), '% < floor ',
                                       put(100 * &min_cluster_pct, 8.0), '%');
            run;
            proc append base=_km_diag data=_km_row force; run;
        %end;
        %else %do;
            /* stability: second fit, fixed seed 777 */
            %seg_km_fit(data=_km_xd, n=&n, d=&d, k=&k, seed=777, n_init=&n_init,
                        out_lab=_km_lb&k, out_cen=_km_cb&k);
            proc sql;
                create table _km_ct as
                select a.lab as la, b.lab as lb, count(*) as nij
                from _km_la&k a inner join _km_lb&k b on a._rid = b._rid group by a.lab, b.lab;
                create table _km_ra as select la, sum(nij) as ni from _km_ct group by la;
                create table _km_rb as select lb, sum(nij) as nj from _km_ct group by lb;
            quit;
            data _null_;
                set _km_ct end=_e; sij + nij * (nij - 1) / 2;
                if _e then call symputx('sij', sij, 'L');
            run;
            data _null_;
                set _km_ra end=_e; sa + ni * (ni - 1) / 2;
                if _e then call symputx('sa', sa, 'L');
            run;
            data _null_;
                set _km_rb end=_e; sb + nj * (nj - 1) / 2;
                if _e then call symputx('sb', sb, 'L');
            run;
            data _null_;
                ex  = &sa * &sb / (&n * (&n - 1) / 2);
                den = 0.5 * (&sa + &sb) - ex;
                ari = ifn(den = 0, 1, (&sij - ex) / den);
                call symputx('ari', put(ari, best32.), 'L');
            run;

            %seg_km_metrics(x=_km_xd, lab=_km_la&k, n=&n, d=&d, k=&k, seed=&seed, out=_km_mt);

            %let drift = .;
            %if %upcase(&drift_aware) = Y %then %do;
                %seg_km_predict(data=_km_xm, cen=_km_ca&k, d=&d, k=&k, out=_km_pm);
                proc sql noprint;
                    create table _km_dp as select lab, count(*) / &n as dp from _km_la&k group by lab;
                    create table _km_mp as select lab, count(*) / &nmon as mp from _km_pm group by lab;
                    select max(abs(coalesce(m.mp, 0) - d.dp) / (case when d.dp > 1e-6 then d.dp else 1e-6 end)) format=best32. into :drift trimmed
                    from _km_dp d left join _km_mp m on d.lab = m.lab;
                quit;
            %end;

            data _km_row;
                set _km_mt;
                length rejected_reason $100;
                k = &k; stability_ari = &ari; max_cluster_drift = &drift;
                min_cluster_pct = &minfrac; composite = .; rejected_reason = '';
            run;
            proc append base=_km_diag data=_km_row force; run;
        %end;

      %end;
    %end;

    /* ---- composite score over the accepted ks ---- */
    proc sql noprint;
        select min(silhouette) format=best32., max(silhouette) format=best32., min(calinski_harabasz) format=best32., max(calinski_harabasz) format=best32.,
               min(davies_bouldin) format=best32., max(davies_bouldin) format=best32., min(stability_ari) format=best32., max(stability_ari) format=best32.,
               min(max_cluster_drift) format=best32., max(max_cluster_drift) format=best32.
          into :s_lo trimmed, :s_hi trimmed, :c_lo trimmed, :c_hi trimmed, :d_lo trimmed, :d_hi trimmed,
               :t_lo trimmed, :t_hi trimmed, :m_lo trimmed, :m_hi trimmed
          from _km_diag where missing(rejected_reason);
    quit;

    data _km_diag;
        set _km_diag;
        if missing(rejected_reason) then do;
            if &s_hi > &s_lo then sil_n = (silhouette - &s_lo) / (&s_hi - &s_lo); else sil_n = 1;
            if &c_hi > &c_lo then ch_n  = (calinski_harabasz - &c_lo) / (&c_hi - &c_lo); else ch_n = 1;
            if &d_hi > &d_lo then db_n  = 1 - (davies_bouldin - &d_lo) / (&d_hi - &d_lo); else db_n = 0;
            if &t_hi > &t_lo then stb_n = (stability_ari - &t_lo) / (&t_hi - &t_lo); else stb_n = 1;
            internal = mean(sil_n, ch_n, db_n);
            %if %upcase(&drift_aware) = Y %then %do;
                if &m_hi > &m_lo then drf_n = (max_cluster_drift - &m_lo) / (&m_hi - &m_lo); else drf_n = 1;
                composite = (1 - &drift_weight) * (0.5 * internal + 0.5 * stb_n) + &drift_weight * drf_n;
            %end;
            %else %do;
                composite = 0.5 * internal + 0.5 * stb_n;
            %end;
        end;
        drop sil_n ch_n db_n stb_n internal drf_n;
    run;

    proc sql outobs=1 noprint;
        select k into :sg_km_bestk trimmed from _km_diag where missing(rejected_reason)
        order by composite desc, k;
    quit;
    %if not %length(&sg_km_bestk) %then %put ERROR: seg_km_select_k - no k satisfied the minimum cluster-size floor.;
    %else %put NOTE: seg_km_select_k - selected k=&sg_km_bestk;

%mend seg_km_select_k;
