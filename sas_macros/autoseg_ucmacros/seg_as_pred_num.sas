/* ============================================================================
   seg_as_pred_num.sas
   AutoSlicer predicates for ONE numeric feature (techniques/autoslicer.py:
   build_feature_bins). Quantile bins are fit on DEV non-missing values:
     edges = unique(numpy-linear quantiles at linspace(0,1,nbins+1));
     first/last edge -> -inf/+inf; bin j = [edge_j, edge_j+1).
   Appends predicates to _sg_pred and adds column _b&i (matched pred_id, or -1
   for missing) to _sg_dev and _sg_mon. Missing never matches a numeric bin
   (SAS would otherwise treat missing as smaller than every number).
   Requires: sg_npred (running pred counter), seg_quantile_t7_by, seg_fmtnum
   ============================================================================ */
%macro seg_as_pred_num(f=, i=, nbins=);

    %local base knew side tab;
    %let base = &sg_npred;

    data _sg_x;
        set _sg_dev(keep=&f);
        where not missing(&f);
        _g = 1;
    run;
    proc sort data=_sg_x; by _g &f; run;

    %if %seg_nobs(_sg_x) = 0 %then %do;
        data _sg_ed&i; k = 0; array e[30] e1-e30; run;
    %end;
    %else %do;
        %seg_quantile_t7_by(in=_sg_x, by=_g, var=&f, nbins=&nbins, out=_sg_q);

        data _sg_ed&i(keep=k e1-e30)
             _sg_predtmp(keep=pred_id feat_idx feature ptype lower upper lo_inf hi_inf value label);
            set _sg_q;
            array q [0:&nbins] q0-q&nbins;
            array ue[%eval(&nbins + 1)] _u1-_u%eval(&nbins + 1);
            array e [30] e1-e30;
            length feature $64 ptype $1 value $200 label $400 _lo $40 _hi $40;
            nu = 0;
            do _j = 0 to &nbins;                       /* numpy.unique on sorted quantiles */
                if nu = 0 then do; nu = 1; ue[1] = q[_j]; end;
                else if q[_j] ne ue[nu] then do; nu + 1; ue[nu] = q[_j]; end;
            end;
            k = max(nu - 1, 0);                        /* number of bins */
            do _j = 2 to nu - 1; e[_j - 1] = ue[_j]; end;      /* interior edges */
            output _sg_ed&i;

            do _j = 1 to k;
                pred_id  = &base + _j;
                feat_idx = &i;
                feature  = "&f";
                ptype    = 'N';
                value    = '';
                lo_inf   = (_j = 1);
                hi_inf   = (_j = k);
                lower    = ifn(lo_inf, ., ue[_j]);
                upper    = ifn(hi_inf, ., ue[_j + 1]);
                if lo_inf and hi_inf then label = catx(' ', "&f", '<', 'inf');
                else if lo_inf then do;
                    %seg_fmtnum(x=ue[_j + 1], into=_hi)
                    label = catx(' ', "&f", '<', _hi);
                end;
                else if hi_inf then do;
                    %seg_fmtnum(x=ue[_j], into=_lo)
                    label = catx(' ', "&f", '>=', _lo);
                end;
                else do;
                    %seg_fmtnum(x=ue[_j], into=_lo)
                    %seg_fmtnum(x=ue[_j + 1], into=_hi)
                    label = catx(' ', _lo, '<=', "&f", '<', _hi);
                end;
                output _sg_predtmp;
            end;
        run;

        proc append base=_sg_pred data=_sg_predtmp force; run;
    %end;

    proc sql noprint; select k into :knew trimmed from _sg_ed&i; quit;
    %let sg_npred = %eval(&sg_npred + &knew);

    %do side = 1 %to 2;
        %if &side = 1 %then %let tab = _sg_dev; %else %let tab = _sg_mon;
        data &tab;
            if _n_ = 1 then set _sg_ed&i;
            set &tab;
            array e [30] e1-e30;
            _b&i = -1;
            if not missing(&f) and k >= 1 then do;
                _b&i = &base + k;
                do _j = 1 to k - 1;
                    if &f < e[_j] then do; _b&i = &base + _j; leave; end;
                end;
            end;
            drop k e1-e30 _j;
        run;
    %end;

%mend seg_as_pred_num;
