/* ============================================================================
   seg_as_pred_cat.sas
   AutoSlicer predicates for ONE character feature: one predicate per distinct
   non-missing DEV value, in order of first appearance, only when the feature
   has between 2 and 20 distinct values (generate_single_feature_predicates).
   Rows are mapped to pred_id through a CNTLIN-built character format; unseen
   or missing values map to -1 (never match).
   ============================================================================ */
%macro seg_as_pred_cat(f=, i=);

    %local n base mode side tab;
    %let base = &sg_npred;

    proc sql noprint;
        create table _sg_cv as
        select &f as value length=200, min(_rid) as first_obs
        from _sg_dev
        where not missing(&f)
        group by &f
        order by first_obs;
    quit;
    %let n = %seg_nobs(_sg_cv);

    %if &n > 1 and &n <= 20 %then %do;
        data _sg_predtmp(keep=pred_id feat_idx feature ptype lower upper lo_inf hi_inf value label)
             _sg_cntlin(keep=fmtname type start label hlo);
            set _sg_cv;
            length feature $64 ptype $1 label $400 fmtname $32 type $1 start $200 hlo $1;
            pred_id  = &base + _n_;
            feat_idx = &i;
            feature  = "&f";
            ptype    = 'C';
            lower = .; upper = .; lo_inf = 0; hi_inf = 0;
            label = catx(' ', "&f", '=', value);
            output _sg_predtmp;
            fmtname = "_sgf&i.x"; type = 'C'; start = value; hlo = ' ';
            label = strip(put(pred_id, best12.));
            output _sg_cntlin;
            if _n_ = &n then do;
                start = ''; hlo = 'O'; label = '-1';
                output _sg_cntlin;
            end;
        run;
        proc format cntlin=_sg_cntlin; run;
        proc append base=_sg_pred data=_sg_predtmp force; run;
        %let sg_npred = %eval(&sg_npred + &n);
        %let mode = F;
    %end;
    %else %let mode = X;

    %do side = 1 %to 2;
        %if &side = 1 %then %let tab = _sg_dev; %else %let tab = _sg_mon;
        data &tab;
            set &tab;
            %if &mode = F %then %do;
                _b&i = input(put(&f, $_sgf&i.x.), best12.);
            %end;
            %else %do;
                _b&i = -1;
            %end;
        run;
    %end;

%mend seg_as_pred_cat;
