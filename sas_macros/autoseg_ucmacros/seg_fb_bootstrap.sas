/* ============================================================================
   seg_fb_bootstrap.sas
   Feature Binning significance (bootstrap_signed_difference / add_significance).
   For each candidate: n_iter times, resample the dev rows and the mon rows of
   the segment WITH replacement (independently) and record mon - dev for
     gini, ks, auc, br (bad rate), ece (fast_ece with 10 score bins whose edges
     are the deciles of the segment's combined clipped scores; unclipped means)
   Replicates where a metric is undefined (single class) are skipped for that
   metric. Per metric: 95% CI = 2.5/97.5 percentiles (numpy-linear), point =
   mean, p = min(1, 2*min(P(diff<=0), P(diff>=0))); no valid replicate => p = 1,
   CI missing. RNG: SAS RAND (streaminit seed) - NOT numpy's stream, so p-values
   and CIs agree with Python statistically, not draw-for-draw. With n_iter = 50
   the p-value resolution is coarse (0.04 steps) in BOTH implementations.
   Scale note: the replicate table has ~ n_iter * (n_dev+n_mon) rows per
   candidate; fine for bootstrap_top_n=40 on 5k-row data, use CAS or batching
   for very large data.
   cand : cand_id table (the candidates to bootstrap, premem mode)
   out  : cand_id, <m>_ci_low, <m>_ci_high, <m>_p for m in gini ks auc br ece
   ============================================================================ */
%macro seg_fb_bootstrap(cand=, n_iter=50, seed=42, out=);

    %local side mx m nm;

    %seg_membership(side=dev, cand=&cand, out=_fb_bd, cols=_rid _y _s);
    %seg_membership(side=mon, cand=&cand, out=_fb_bm, cols=_rid _y _s);
    proc sort data=_fb_bd; by cand_id; run;
    proc sort data=_fb_bm; by cand_id; run;

    /* decile edges of the segment's combined clipped scores (for ECE) */
    data _fb_sc;
        set _fb_bd(keep=cand_id _s) _fb_bm(keep=cand_id _s);
        sc = min(max(_s, 1e-6), 1 - 1e-6);
    run;
    proc sort data=_fb_sc; by cand_id sc; run;
    %seg_quantile_t7_by(in=_fb_sc, by=cand_id, var=sc, nbins=10, out=_fb_ed);

    %do side = 0 %to 1;
        %if &side = 0 %then %let m = _fb_bd; %else %let m = _fb_bm;
        proc sql noprint;
            select max(cnt) into :mx trimmed from (select count(*) as cnt from &m group by cand_id);
        quit;

        /* resample every candidate n_iter times (gid = cand_id*1000 + replicate) */
        data _fb_r&side(keep=gid cand_id _y _s);
            array ya [&mx] _temporary_;
            array sa [&mx] _temporary_;
            retain _init 0;
            if not _init then do; call streaminit(&seed + &side); _init = 1; end;
            n = 0;
            do until(last.cand_id);
                set &m(keep=cand_id _y _s);
                by cand_id;
                n + 1; ya[n] = _y; sa[n] = _s;
            end;
            do rep = 1 to &n_iter;
                gid = cand_id * 1000 + rep;
                do i = 1 to n;
                    pick = ceil(rand('uniform') * n);
                    _y = ya[pick]; _s = sa[pick];
                    output;
                end;
            end;
        run;

        /* AUC / KS per replicate */
        data _fb_rk&side(keep=cand_id _y _s);
            set _fb_r&side(keep=gid _y _s rename=(gid=cand_id));
        run;
        %seg_auc_ks(mem=_fb_rk&side, out=_fb_ak&side);

        /* bad rate and ECE (common decile edges) per replicate */
        data _fb_re&side(keep=gid br ece);
            array bn [10] _bn1-_bn10;
            array bs [10] _bs1-_bs10;
            array by_ [10] _by1-_by10;
            if _n_ = 1 then do;
                declare hash he(dataset: '_fb_ed');
                he.defineKey('cand_id');
                he.defineData('q0','q1','q2','q3','q4','q5','q6','q7','q8','q9','q10');
                he.defineDone();
                call missing(q0,q1,q2,q3,q4,q5,q6,q7,q8,q9,q10);
            end;
            set _fb_r&side(keep=gid cand_id _y _s);
            by gid notsorted;
            retain n ysum _bn1-_bn10 _bs1-_bs10 _by1-_by10;
            if first.gid then do;
                rc = he.find();
                n = 0; ysum = 0;
                do j = 1 to 10; bn[j] = 0; bs[j] = 0; by_[j] = 0; end;
            end;
            /* np.digitize on the UNCLIPPED score against edges built from clipped scores */
            b = 1;
            if _s >= q1 then b = 2; if _s >= q2 then b = 3; if _s >= q3 then b = 4;
            if _s >= q4 then b = 5; if _s >= q5 then b = 6; if _s >= q6 then b = 7;
            if _s >= q7 then b = 8; if _s >= q8 then b = 9; if _s >= q9 then b = 10;
            n + 1; ysum + _y; bn[b] + 1; bs[b] + _s; by_[b] + _y;
            if last.gid then do;
                br = ysum / n; ece = 0;
                do j = 1 to 10;
                    if bn[j] > 0 then ece = ece + (bn[j] / n) * abs(bs[j] / bn[j] - by_[j] / bn[j]);
                end;
                output;
            end;
        run;
        proc sort data=_fb_re&side; by gid; run;
    %end;

    /* per-replicate signed differences (mon - dev) */
    data _fb_diff(keep=cand_id gini ks auc br ece);
        merge _fb_ak0(rename=(cand_id=gid auc=auc0 ks=ks0))
              _fb_ak1(rename=(cand_id=gid auc=auc1 ks=ks1))
              _fb_re0(rename=(br=br0 ece=ece0))
              _fb_re1(rename=(br=br1 ece=ece1));
        by gid;
        cand_id = floor(gid / 1000);
        gini = ifn(missing(auc0) or missing(auc1), ., (2 * auc1 - 1) - (2 * auc0 - 1));
        ks   = ifn(missing(ks0) or missing(ks1), ., ks1 - ks0);
        auc  = ifn(missing(auc0) or missing(auc1), ., auc1 - auc0);
        br   = br1 - br0;
        ece  = ece1 - ece0;
    run;

    /* long form -> per candidate/metric summary */
    data _fb_long(keep=key cand_id mi v);
        set _fb_diff;
        array mm [5] gini ks auc br ece;
        do mi = 1 to 5;
            if not missing(mm[mi]) then do; v = mm[mi]; key = cand_id * 10 + mi; output; end;
        end;
    run;
    proc sort data=_fb_long; by key v; run;
    %seg_quantile_t7_by(in=_fb_long, by=key, var=v, nbins=40, out=_fb_lq);   /* q1 = 2.5%, q39 = 97.5% */
    proc sql;
        create table _fb_ls as
        select key, max(cand_id) as cand_id, max(mi) as mi, count(*) as nrep, mean(v) as point,
               sum(v <= 0) / count(*) as p_le, sum(v >= 0) / count(*) as p_ge
        from _fb_long group by key;
        create table _fb_lm as
        select s.cand_id, s.mi, q.q1 as ci_low, q.q39 as ci_high,
               min(1, 2 * min(s.p_le, s.p_ge)) as p
        from _fb_ls s inner join _fb_lq q on s.key = q.key;
    quit;

    /* every candidate x metric, defaults where no valid replicate */
    data _fb_mi; do mi = 1 to 5; output; end; run;
    proc sql;
        create table _fb_grid as
        select c.cand_id, m.mi from &cand c, _fb_mi m;
    quit;
    proc sql;
        create table _fb_all as
        select g.cand_id, g.mi, l.ci_low, l.ci_high, coalesce(l.p, 1) as p
        from _fb_grid g left join _fb_lm l on g.cand_id = l.cand_id and g.mi = l.mi;
    quit;

    proc sql;
        create table &out as
        select cand_id,
               max(case when mi = 1 then ci_low  end) as gini_ci_low,
               max(case when mi = 1 then ci_high end) as gini_ci_high,
               max(case when mi = 1 then p       end) as gini_p,
               max(case when mi = 2 then ci_low  end) as ks_ci_low,
               max(case when mi = 2 then ci_high end) as ks_ci_high,
               max(case when mi = 2 then p       end) as ks_p,
               max(case when mi = 3 then ci_low  end) as auc_ci_low,
               max(case when mi = 3 then ci_high end) as auc_ci_high,
               max(case when mi = 3 then p       end) as auc_p,
               max(case when mi = 4 then ci_low  end) as br_ci_low,
               max(case when mi = 4 then ci_high end) as br_ci_high,
               max(case when mi = 4 then p       end) as br_p,
               max(case when mi = 5 then ci_low  end) as ece_ci_low,
               max(case when mi = 5 then ci_high end) as ece_ci_high,
               max(case when mi = 5 then p       end) as ece_p
        from _fb_all group by cand_id order by cand_id;
    quit;

%mend seg_fb_bootstrap;
