/* ============================================================================
   seg_fb_bins_cat.sas
   Feature Binning bins for ONE character feature (build_categorical_bins):
     * categories (missing -> '__MISSING__') ordered by dev bad rate ascending
       (ties: alphabetical, which is what pandas' stable sort on the
       alphabetically grouped counts gives)
     * <= max_bins distinct values : one bin per category with dev share >=
       min_bin_pct; the '__MISSING__' category becomes btype 'missing'
       ("<f> is Missing"), the others "<f> = value"
     * more than max_bins values   : equal-count groups of the bad-rate-ordered
       categories (pd.qcut on the ranks into max_bins groups); a group whose dev
       share is below min_bin_pct is dropped; label "<f> IN (a, b, ...)"
   Appends to _fb_bin and to _fb_cat (bin_id, value) which lists the categories
   of every categorical bin. Requires global sg_fb_nbin.
   ============================================================================ */
%macro seg_fb_bins_cat(f=, i=, max_bins=8, min_bin_pct=0.01);

    %local m;

    proc sql;
        create table _fb_c0 as
        select coalescec(strip(&f), '__MISSING__') as value length=200,
               count(*) as cnt, mean(_y) as bad
        from _sg_dev
        group by calculated value
        order by bad, value;
    quit;
    %let m = %seg_nobs(_fb_c0);

    %if &m > 0 %then %do;

        data _fb_c1;
            set _fb_c0;
            r = _n_;
            share = cnt / &sg_ndev;
            %if &m <= &max_bins %then %do;
                grp = r;
            %end;
            %else %do;
                /* pd.qcut(rank, q=max_bins): numpy-linear edges of ranks 1..m, right-closed bins */
                array e [0:&max_bins] _e0-_e&max_bins;
                retain _e0-_e&max_bins;
                if _n_ = 1 then do;
                    do _j = 0 to &max_bins;
                        _p = ifn(_j = &max_bins, 1, _j * (1 / &max_bins));
                        _h = (&m - 1) * _p; _lo = floor(_h); _g = _h - _lo;
                        _a = _lo + 1; _b = min(_lo + 1, &m - 1) + 1; _d = _b - _a;
                        e[_j] = ifn(_g >= 0.5, _b - _d * (1 - _g), _a + _d * _g);
                    end;
                end;
                grp = 0;
                do _j = 1 to &max_bins - 1;
                    if e[_j] < r then grp = grp + 1;
                end;
                grp = grp + 1;
            %end;
        run;

        proc sql;
            create table _fb_g as
            select grp, sum(cnt) / &sg_ndev as gshare, min(r) as r0
            from _fb_c1 group by grp
            having sum(cnt) / &sg_ndev >= &min_bin_pct
            order by grp;
        quit;
        data _fb_g; set _fb_g; bin_ord = _n_; run;

        data _fb_b3(keep=bin_id feat_idx feature btype lower upper lo_inf hi_inf label);
            length feature $64 btype $10 label $400 _list $1000;
            set _fb_g;
            _list = '';
            _single = 0;
            %if &m <= &max_bins %then %do;
                /* one category per bin */
                _rr = r0;
                set _fb_c1(keep=r value rename=(r=_r2 value=_val)) point=_rr;
                _list = _val;
                _single = 1;
            %end;
            bin_id = &sg_fb_nbin + _n_; feat_idx = &i; feature = "&f";
            lower = .; upper = .; lo_inf = 0; hi_inf = 0;
            %if &m <= &max_bins %then %do;
                if _val = '__MISSING__' then do; btype = 'missing'; label = "&f is Missing"; end;
                else do; btype = 'categorical'; label = catx(' ', "&f", '=', _val); end;
            %end;
            %else %do;
                btype = 'categorical'; label = "&f IN (...)";
            %end;
            output;
        run;

        /* category membership of every categorical bin */
        proc sql;
            create table _fb_cm as
            select &sg_fb_nbin + g.bin_ord as bin_id, c.value
            from _fb_g g
                 inner join _fb_c1 c on c.grp = g.grp
            order by bin_id, c.r;
        quit;
        proc append base=_fb_cat data=_fb_cm force; run;

        /* multi-category labels: "f IN (a, b, ...)" in bad-rate order */
        %if &m > &max_bins %then %do;
            data _fb_lab(keep=bin_id _lab);
                set _fb_cm; by bin_id;
                length _lab $400;
                retain _lab;
                if first.bin_id then _lab = value; else _lab = catx(', ', _lab, value);
                if last.bin_id then output;
            run;
            proc sql;
                update _fb_b3 b set label =
                    (select case when l._lab = '__MISSING__' then "&f is Missing"
                                 else cats("&f", ' IN (', strip(l._lab), ')') end
                     from _fb_lab l where l.bin_id = b.bin_id);
            quit;
        %end;

        proc append base=_fb_bin data=_fb_b3 force; run;
        proc sql noprint; select count(*) into :m trimmed from _fb_g; quit;
        %let sg_fb_nbin = %eval(&sg_fb_nbin + &m);
    %end;

%mend seg_fb_bins_cat;
