/* ============================================================================
   seg_fb_calib.sas
   Feature Binning's own calibration diagnostics per candidate and side
   (compute_calibration_stats):
     ECE       : scores clipped to [1e-6, 1-1e-6], cut into 10 quantile bins
                 (pd.qcut, numpy-linear edges, duplicates dropped, right-closed);
                 ECE = sum_b (n_b/n) * |mean(score_b) - mean(target_b)|
                 (means use the UNclipped score, as Python does)
     intercept / slope : unregularised logistic regression of target on the
                 clipped RAW score (not on logit(score)) - PROC LOGISTIC MLE.
                 Python fits sklearn LogisticRegression(C=1e9, lbfgs,
                 max_iter=200), which approximates the same MLE; small
                 differences are expected where lbfgs stops early. Missing if
                 the segment has a single target class.
   NOTE: FB's "Calibration_Drift" in the combined output is the intercept shift,
   a different quantity from the A/E-ratio shift the other four techniques call
   Calibration_Drift (the A/E shift is also produced by the shared engine).
   mem_dev / mem_mon : cand_id, _y, _s        out: one row per candidate
   ============================================================================ */
%macro seg_fb_calib(mem_dev=, mem_mon=, out=);

    %local side tab sfx;

    %do side = 1 %to 2;
        %if &side = 1 %then %do; %let tab = &mem_dev; %let sfx = dev; %end;
        %else %do; %let tab = &mem_mon; %let sfx = mon; %end;

        /* ---- ECE ---- */
        data _fc_s;
            set &tab(keep=cand_id _y _s);
            sc = min(max(_s, 1e-6), 1 - 1e-6);
        run;
        proc sort data=_fc_s; by cand_id sc; run;
        %seg_quantile_t7_by(in=_fc_s, by=cand_id, var=sc, nbins=10, out=_fc_q);

        data _fc_e&sfx(keep=cand_id ece_&sfx);
            merge _fc_s _fc_q(keep=cand_id q0-q10);
            by cand_id;
            array q [0:10] q0-q10;
            array ue[11] _u1-_u11;
            array bn[10] _bn1-_bn10;
            array bs[10] _bs1-_bs10;
            array by_[10] _by1-_by10;
            retain nu ntot _u1-_u11 _bn1-_bn10 _bs1-_bs10 _by1-_by10;
            if first.cand_id then do;
                nu = 0;
                do _j = 0 to 10;
                    if nu = 0 then do; nu = 1; ue[1] = q[_j]; end;
                    else if q[_j] ne ue[nu] then do; nu + 1; ue[nu] = q[_j]; end;
                end;
                do _j = 1 to 10; bn[_j] = 0; bs[_j] = 0; by_[_j] = 0; end;
                ntot = 0;
            end;
            _b = 1;
            do _j = 2 to nu - 1;
                if sc > ue[_j] then _b + 1;
            end;
            bn[_b] + 1; bs[_b] + _s; by_[_b] + _y; ntot + 1;
            if last.cand_id then do;
                ece_&sfx = 0;
                do _j = 1 to nu - 1;
                    if bn[_j] > 0 then ece_&sfx = ece_&sfx + (bn[_j] / ntot) * abs(bs[_j] / bn[_j] - by_[_j] / bn[_j]);
                end;
                output;
            end;
        run;

        /* ---- logistic intercept / slope (candidates with both classes) ---- */
        proc sql;
            create table _fc_l as
            select cand_id, _y, min(max(_s, 1e-6), 1 - 1e-6) as sc
            from &tab
            where cand_id in (select cand_id from &tab group by cand_id
                              having min(_y) = 0 and max(_y) = 1)
            order by cand_id;
        quit;
        %if %seg_nobs(_fc_l) > 0 %then %do;
            ods select none;
            proc logistic data=_fc_l;
                by cand_id;
                model _y(event='1') = sc;
                ods output ParameterEstimates=_fc_pe;
            run;
            ods select all;
            proc sql;
                create table _fc_c&sfx as
                select cand_id,
                       max(case when upcase(Variable) = 'INTERCEPT' then Estimate else . end) as cal_&sfx._intercept,
                       max(case when upcase(Variable) = 'SC' then Estimate else . end) as cal_&sfx._slope
                from _fc_pe group by cand_id;
            quit;
        %end;
        %else %do;
            data _fc_c&sfx; length cand_id 8 cal_&sfx._intercept 8 cal_&sfx._slope 8; stop; run;
        %end;
    %end;

    data &out;
        merge _fc_edev _fc_emon _fc_cdev _fc_cmon;
        by cand_id;
        if missing(cal_dev_intercept) or missing(cal_mon_intercept) then delta_intercept = .;
        else delta_intercept = cal_mon_intercept - cal_dev_intercept;
        if missing(cal_dev_slope) or missing(cal_mon_slope) then delta_slope = .;
        else delta_slope = cal_mon_slope - cal_dev_slope;
        if missing(ece_dev) or missing(ece_mon) then delta_ece = .;
        else delta_ece = ece_mon - ece_dev;
    run;

%mend seg_fb_calib;
