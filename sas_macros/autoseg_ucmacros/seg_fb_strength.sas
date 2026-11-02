/* ============================================================================
   seg_fb_strength.sas
   Feature Binning step 1 (techniques/feature_binning.py: get_candidate_features,
   feature_strength, select_top_features): keep legitimate features and rank them
   by how strongly they separate the target on DEV data.
     numeric     : |AUC(target, value over non-missing rows) - 0.5|
     categorical : |AUC(target, bad-rate-encoded value) - 0.5|, missing = '__MISSING__'
   (AUC with mid-rank ties = sklearn.roc_auc_score; <2 usable rows or a single
   target class => strength 0). The top max_features by strength are returned in
   strength order (ties: original feature order).
   Name guard (as get_candidate_features): drops shap_*, *_id, id_*, and names
   containing customer_id / account_id / application_id.
   Global result: sg_fb_sel (space-separated feature list)
   ============================================================================ */
%macro seg_fb_strength(feature_cols=, max_features=30);

    %global sg_fb_sel;
    %local nf i f vt ok;
    %let nf = %sysfunc(countw(&feature_cols, %str( )));

    data _fb_str;
        length feat_idx 8 feature $64 strength 8;
        stop;
    run;

    %do i = 1 %to &nf;
        %let f = %scan(&feature_cols, &i, %str( ));
        data _null_;
            length nm $64;
            nm  = lowcase("&f");
            bad = prxmatch('/^shap_|^id_|_id$|customer_id|account_id|application_id/', strip(nm)) > 0;
            call symputx('ok', not bad, 'L');
        run;
        %if &ok %then %do;
            %let vt = %seg_vartype(ds=_sg_dev, var=&f);
            %if &vt = N %then %do;
                data _fb_s1; set _sg_dev(keep=_y &f); where not missing(&f); _x = &f; run;
            %end;
            %else %do;
                proc sql;
                    create table _fb_s1 as
                    select a._y, b.enc as _x
                    from (select _y, coalescec(strip(&f), '__MISSING__') as v from _sg_dev) a
                    inner join (select coalescec(strip(&f), '__MISSING__') as v, mean(_y) as enc
                                from _sg_dev group by calculated v) b on a.v = b.v;
                quit;
            %end;

            data _fb_s0; strength = 0; run;
            %if %seg_nobs(_fb_s1) >= 2 %then %do;
                proc rank data=_fb_s1 out=_fb_s2 ties=mean; var _x; ranks _r; run;
                proc sql noprint;
                    select sum(_y = 1), sum(_y = 0), sum(case when _y = 1 then _r else 0 end) format=best32.
                      into :n1 trimmed, :n0 trimmed, :r1 trimmed from _fb_s2;
                quit;
                data _fb_s0;
                    n1 = &n1; n0 = &n0; r1 = &r1;
                    if n1 > 0 and n0 > 0 then strength = abs((r1 - n1 * (n1 + 1) / 2) / (n1 * n0) - 0.5);
                    else strength = 0;
                run;
            %end;
            data _fb_s3; set _fb_s0(keep=strength); length feature $64; feat_idx = &i; feature = "&f"; run;
            proc append base=_fb_str data=_fb_s3 force; run;
        %end;
    %end;

    proc sort data=_fb_str; by descending strength feat_idx; run;
    data _fb_str2; set _fb_str(obs=&max_features); run;
    proc sql noprint;
        select feature into :sg_fb_sel separated by ' ' from _fb_str2;
    quit;
    %put NOTE: seg_fb_strength - selected features: &sg_fb_sel;

%mend seg_fb_strength;
