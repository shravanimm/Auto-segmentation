/* ============================================================================
   seg_tree_matrix.sas
   SAS port of utils/preprocessing.build_feature_matrix for the tree techniques
   (Drift Tree, Gradient Boosting), applied to the COMBINED dev+mon rows:
     * numeric columns: missing -> median of the combined column, then rounded
       to float32 (scikit-learn casts X to float32 before fitting/applying)
     * categorical columns: one 0/1 column per distinct value of the combined
       data in sorted order (missing -> the string 'nan', as astype(str) does; K-Means passes
       miss=__MISSING__ and scope=DEV)
   Column order = numeric_cols then categorical_cols, as in Python.

   in  : _sg_dev / _sg_mon (from seg_prep)
   out : &out  (_tid 1..ndev+nmon [dev first], y = 1 for monitoring, x1..xp)
         &map  (fidx, kind N|C, src_idx, srcname, val)  maps x<fidx> back to its
               source feature (and category) - used to render/canonicalise rules
   Global: sg_tr_p = number of generated columns p
   Requires: sg_ndev sg_nmon
   ============================================================================ */
%macro seg_tree_matrix(numeric_cols=, categorical_cols=, out=_tr_x, map=_tr_map, scope=COMBINED, miss=nan);

    %global sg_tr_p;
    %local nn nc j c v p med;

    %let nn = %sysfunc(countw(&numeric_cols, %str( )));
    %let nc = %sysfunc(countw(&categorical_cols, %str( )));

    %if %upcase(&scope) = DEV %then %do;
        /* K-Means rule distillation: dev rows only, _tid = dev row id */
        data _tr_stk;
            set _sg_dev(keep=&numeric_cols &categorical_cols);
            y    = 0;
            _tid = _n_;
        run;
    %end;
    %else %do;
        data _tr_stk;
            set _sg_dev(in=_a keep=&numeric_cols &categorical_cols)
                _sg_mon(keep=&numeric_cols &categorical_cols);
            y    = (_a = 0);
            _tid = _n_;
        run;
    %end;

    /* ---- map: numeric columns first, then categories of each categorical column ---- */
    data &map;
        length fidx 8 kind $1 src_idx 8 srcname $64 val $200;
        stop;
    run;
    %do j = 1 %to &nn;
        %let v = %scan(&numeric_cols, &j, %str( ));
        data _tr_m1; length kind $1 srcname $64 val $200; kind = 'N'; src_idx = &j; srcname = "&v"; val = ''; run;
        proc append base=&map data=_tr_m1 force; run;
    %end;
    %do c = 1 %to &nc;
        %let v = %scan(&categorical_cols, &c, %str( ));
        proc sql;
            create table _tr_m2 as
            select distinct 'C' as kind length=1, %eval(&nn + &c) as src_idx, "&v" as srcname length=64,
                   coalescec(strip(&v), "&miss") as val length=200
            from _tr_stk
            order by val;
        quit;
        proc append base=&map data=_tr_m2 force; run;
    %end;
    data &map; set &map; fidx = _n_; run;
    proc sql noprint; select count(*) into :p trimmed from &map; quit;
    %let sg_tr_p = &p;

    /* ---- medians of the combined numeric columns ---- */
    %if &nn > 0 %then %do;
        proc means data=_tr_stk noprint;
            var &numeric_cols;
            output out=_tr_med(drop=_type_ _freq_) median=;
        run;
        data _null_;
            set _tr_med;
            %do j = 1 %to &nn;
                call symputx("med&j", put(%scan(&numeric_cols, &j, %str( )), best32.), 'L');
            %end;
        run;
    %end;

    /* ---- matrix: float32-rounded numeric values + one-hot indicators ---- */
    data &out(keep=_tid y x1-x&p);
        array x [&p] x1-x&p;
        array mval  [&p] $200 _temporary_;
        array msrc  [&p] _temporary_;
        array mkind [&p] $1 _temporary_;
        if _n_ = 1 then do;
            do until(_e);
                set &map(keep=fidx kind src_idx val) end=_e;
                mval[fidx] = val; msrc[fidx] = src_idx; mkind[fidx] = kind;
            end;
        end;
        set _tr_stk;
        %do j = 1 %to &nn;
            %let v = %scan(&numeric_cols, &j, %str( ));
            _t = coalesce(&v, &&med&j);
            %seg_f32(x=_t, into=_t32)
            x[&j] = _t32;
        %end;
        %do c = 1 %to &nc;
            %let v = %scan(&categorical_cols, &c, %str( ));
            _v = coalescec(strip(&v), "&miss");
            do _k = %eval(&nn + 1) to &p;
                if mkind[_k] = 'C' and msrc[_k] = %eval(&nn + &c) then x[_k] = (mval[_k] = _v);
            end;
        %end;
    run;

%mend seg_tree_matrix;
