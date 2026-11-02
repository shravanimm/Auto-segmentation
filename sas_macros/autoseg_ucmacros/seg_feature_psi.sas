/* ============================================================================
   seg_feature_psi.sas
   In-segment root-cause drift: for EVERY candidate and every root-cause
   feature, PSI between the segment's dev rows and mon rows
   (core/candidate_evaluation._compute_feature_drift_within_segment).

   numeric feature (physical SAS type):
       bins = unique(numpy-linear deciles of the COMBINED dev+mon non-missing
       values of the segment), outer edges -> +-inf, intervals (a,b]
       (right-closed, as pandas.cut). pct = (count+1e-6)/(total+1e-6*nbins);
       PSI = sum (m-d)*ln(m/d), floored at 0. Constant feature => 0.
   character feature:
       union of categories, pct = (count+1e-6)/(total+1e-6), PSI as above.
   A feature is skipped for a candidate when either side has < 5 non-missing
   values. NOTE this is NOT drift_psi_one_feature.sas (that macro bins on DEV
   only and clamps with coalesce); the two differ by design in Python.

   Outputs:
     &out_long : cand_id, feat_idx, feature, psi
     &out_agg  : cand_id, mean_feature_psi (0 if no valid feature),
                 top_drift_feature (first feature on ties), top_drift_psi
   mem_dev / mem_mon must carry the feature columns (see cols= in seg_membership).
   ============================================================================ */
%macro seg_feature_psi(mem_dev=, mem_mon=, feats=, cnt=, out_long=, out_agg=);

    %local nfe i f vt;
    %let nfe = %sysfunc(countw(&feats, %str( )));

    data &out_long;
        length cand_id 8 feat_idx 8 feature $64 psi 8;
        stop;
    run;

    %do i = 1 %to &nfe;
        %let f  = %scan(&feats, &i, %str( ));
        %let vt = %seg_vartype(ds=_sg_dev, var=&f);

        data _sg_fs;
            set &mem_dev(keep=cand_id &f rename=(&f=_v))
                &mem_mon(keep=cand_id &f rename=(&f=_v) in=_im);
            src = _im;
            if not missing(_v);
        run;

        proc sql;
            create table _sg_fok as
            select cand_id from _sg_fs
            group by cand_id
            having sum(src = 0) >= 5 and sum(src = 1) >= 5;

            create table _sg_fs2 as
            select * from _sg_fs
            where cand_id in (select cand_id from _sg_fok)
            order by cand_id, _v;
        quit;

        %if %seg_nobs(_sg_fs2) > 0 %then %do;

            %if &vt = N %then %do;
                %seg_quantile_t7_by(in=_sg_fs2, by=cand_id, var=_v, nbins=10, out=_sg_fq);

                data _sg_fpn(keep=cand_id psi);
                    merge _sg_fs2(keep=cand_id _v src) _sg_fq(keep=cand_id q0-q10);
                    by cand_id;
                    array q [0:10] q0-q10;
                    array ue[11] _u1-_u11;
                    array cd[10] _cd1-_cd10;
                    array cm[10] _cm1-_cm10;
                    retain nu k nd nm _u1-_u11 _cd1-_cd10 _cm1-_cm10;
                    if first.cand_id then do;
                        nu = 0;
                        do _j = 0 to 10;
                            if nu = 0 then do; nu = 1; ue[1] = q[_j]; end;
                            else if q[_j] ne ue[nu] then do; nu + 1; ue[nu] = q[_j]; end;
                        end;
                        k = nu - 1;
                        do _j = 1 to 10; cd[_j] = 0; cm[_j] = 0; end;
                        nd = 0; nm = 0;
                    end;
                    _b = 1;
                    do _j = 2 to nu - 1;
                        if _v > ue[_j] then _b + 1;
                    end;
                    if nu >= 2 then do;
                        if src = 0 then do; cd[_b] + 1; nd + 1; end;
                        else do; cm[_b] + 1; nm + 1; end;
                    end;
                    if last.cand_id then do;
                        psi = 0;
                        if nu >= 2 then do;
                            do _j = 1 to k;
                                _pd = (cd[_j] + 1e-6) / (nd + 1e-6 * k);
                                _pm = (cm[_j] + 1e-6) / (nm + 1e-6 * k);
                                psi = psi + (_pm - _pd) * log(_pm / _pd);
                            end;
                        end;
                        psi = max(0, psi);
                        output;
                    end;
                run;
            %end;
            %else %do;
                proc sql;
                    create table _sg_fc as
                    select cand_id, _v, sum(src = 0) as cd, sum(src = 1) as cm
                    from _sg_fs2 group by cand_id, _v;

                    create table _sg_fcn as
                    select cand_id, sum(cd) as nd, sum(cm) as nm from _sg_fc group by cand_id;

                    create table _sg_fpc0 as
                    select a.cand_id,
                           sum( ((a.cm + 1e-6) / (n.nm + 1e-6) - (a.cd + 1e-6) / (n.nd + 1e-6))
                                * log( ((a.cm + 1e-6) / (n.nm + 1e-6)) / ((a.cd + 1e-6) / (n.nd + 1e-6)) ) )
                                as psi_raw
                    from _sg_fc a inner join _sg_fcn n on a.cand_id = n.cand_id
                    group by a.cand_id;
                quit;
                data _sg_fpn(keep=cand_id psi);
                    set _sg_fpc0;
                    psi = max(0, psi_raw);
                run;
            %end;

            data _sg_fp1;
                set _sg_fpn;
                length feature $64;
                feat_idx = &i;
                feature  = "&f";
            run;
            proc append base=&out_long data=_sg_fp1 force; run;
        %end;
    %end;

    proc sort data=&out_long; by cand_id descending psi feat_idx; run;

    data _sg_fagg0(keep=cand_id mean_feature_psi top_drift_feature top_drift_psi);
        set &out_long;
        by cand_id;
        length top_drift_feature $64;
        retain top_drift_feature top_drift_psi _sum _n;
        if first.cand_id then do;
            top_drift_feature = feature;
            top_drift_psi     = psi;
            _sum = 0; _n = 0;
        end;
        _sum + psi;
        _n + 1;
        if last.cand_id then do;
            mean_feature_psi = _sum / _n;
            output;
        end;
    run;

    /* candidates with no valid feature: Python returns None / 0.0 / 0.0 */
    data &out_agg;
        merge &cnt(keep=cand_id) _sg_fagg0;
        by cand_id;
        if missing(mean_feature_psi) then mean_feature_psi = 0;
        if missing(top_drift_psi)    then top_drift_psi    = 0;
    run;

%mend seg_feature_psi;
