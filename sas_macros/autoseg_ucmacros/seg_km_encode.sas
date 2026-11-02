/* ============================================================================
   seg_km_encode.sas
   Port of techniques/kmeans.fit_encoder + transform. Fit on DEVELOPMENT only,
   applied unchanged to monitoring:
     numeric     : missing -> dev median, then (x - mean) / std
                   (StandardScaler: population std, ddof = 0; std 0 -> 1)
     categorical : missing -> '__MISSING__'; one 0/1 column per distinct DEV
                   value in sorted order (unseen monitoring values -> all zeros)
   Column order: numeric cols, then each categorical col's values.
   out: _km_xd (dev) and _km_xm (mon): _rid, d1..dD ;  _km_map: fidx kind
        src_idx srcname val med mean std (scaler stats, also published)
   Global: sg_km_d = D
   Outlier treatment (OutlierConfig) is off by default in Python and is not ported.
   ============================================================================ */
%macro seg_km_encode(numeric_cols=, categorical_cols=);

    %global sg_km_d;
    %local nn nc j c v d side tab out;

    %let nn = %sysfunc(countw(&numeric_cols, %str( )));
    %let nc = %sysfunc(countw(&categorical_cols, %str( )));

    %if &nn > 0 %then %do;
        proc means data=_sg_dev noprint;
            var &numeric_cols;
            output out=_km_med(drop=_type_ _freq_) median=;
        run;
        data _null_;
            set _km_med;
            %do j = 1 %to &nn;
                call symputx("km_med&j", put(%scan(&numeric_cols, &j, %str( )), best32.), 'L');
            %end;
        run;
        data _km_imp;
            set _sg_dev(keep=&numeric_cols);
            %do j = 1 %to &nn;
                %let v = %scan(&numeric_cols, &j, %str( ));
                &v = coalesce(&v, &&km_med&j);
            %end;
        run;
        proc means data=_km_imp noprint vardef=n;
            var &numeric_cols;
            output out=_km_mean(drop=_type_ _freq_) mean=;
            output out=_km_std(drop=_type_ _freq_) std=;
        run;
        data _null_;
            merge _km_mean _km_std(rename=(%do j = 1 %to &nn; %scan(&numeric_cols, &j, %str( ))=s&j %end;));
            %do j = 1 %to &nn;
                call symputx("km_mean&j", put(%scan(&numeric_cols, &j, %str( )), best32.), 'L');
                call symputx("km_std&j", put(ifn(s&j = 0 or missing(s&j), 1, s&j), best32.), 'L');
            %end;
        run;
    %end;

    data _km_map;
        length fidx 8 kind $1 src_idx 8 srcname $64 val $200 med 8 mean 8 std 8;
        stop;
    run;
    %do j = 1 %to &nn;
        %let v = %scan(&numeric_cols, &j, %str( ));
        data _km_m1;
            length kind $1 srcname $64 val $200;
            kind = 'N'; src_idx = &j; srcname = "&v"; val = '';
            med = &&km_med&j; mean = &&km_mean&j; std = &&km_std&j;
        run;
        proc append base=_km_map data=_km_m1 force; run;
    %end;
    %do c = 1 %to &nc;
        %let v = %scan(&categorical_cols, &c, %str( ));
        proc sql;
            create table _km_m2 as
            select distinct 'C' as kind length=1, %eval(&nn + &c) as src_idx,
                   "&v" as srcname length=64, coalescec(strip(&v), '__MISSING__') as val length=200
            from _sg_dev order by val;
        quit;
        proc append base=_km_map data=_km_m2 force; run;
    %end;
    data _km_map; set _km_map; fidx = _n_; run;
    proc sql noprint; select count(*) into :d trimmed from _km_map; quit;
    %let sg_km_d = &d;

    %do side = 1 %to 2;
        %if &side = 1 %then %do; %let tab = _sg_dev; %let out = _km_xd; %end;
        %else %do; %let tab = _sg_mon; %let out = _km_xm; %end;
        data &out(keep=_rid d1-d&d);
            array dd [&d] d1-d&d;
            array mval  [&d] $200 _temporary_;
            array msrc  [&d]      _temporary_;
            array mkind [&d] $1   _temporary_;
            if _n_ = 1 then do;
                do until(_e);
                    set _km_map(keep=fidx kind src_idx val) end=_e;
                    mval[fidx] = val; msrc[fidx] = src_idx; mkind[fidx] = kind;
                end;
            end;
            set &tab;
            %do j = 1 %to &nn;
                %let v = %scan(&numeric_cols, &j, %str( ));
                dd[&j] = (coalesce(&v, &&km_med&j) - &&km_mean&j) / &&km_std&j;
            %end;
            %do c = 1 %to &nc;
                %let v = %scan(&categorical_cols, &c, %str( ));
                _v = coalescec(strip(&v), '__MISSING__');
                do _k = %eval(&nn + 1) to &d;
                    if mkind[_k] = 'C' and msrc[_k] = %eval(&nn + &c) then dd[_k] = (mval[_k] = _v);
                end;
            %end;
        run;
    %end;

%mend seg_km_encode;
