/* ============================================================================
   seg_as_predicates.sas
   Builds the AutoSlicer atomic predicate catalogue.
   Output _sg_pred: pred_id (global, 1..n, feature order then bin order),
     feat_idx, feature, ptype (N|C), lower, upper (missing = open end),
     lo_inf, hi_inf, value, label.
   Side effect: adds _b1.._bN to _sg_dev and _sg_mon (N = number of features);
   _b&i = pred_id of the (single) predicate of feature i that the row satisfies.
   Because the predicates of one feature are mutually exclusive, a row matches
   a conjunction iff _b&i equals the conjunction's pred_id for every feature it
   constrains - which turns mask evaluation into an integer join.
   ============================================================================ */
%macro seg_as_predicates(feature_cols=, numeric_bins=4);

    %global sg_npred;
    %local i f vt;
    %let sg_npred = 0;

    data _sg_pred;
        length pred_id 8 feat_idx 8 feature $64 ptype $1 lower 8 upper 8 lo_inf 8 hi_inf 8
               value $200 label $400;
        stop;
    run;

    %do i = 1 %to &sg_nf;
        %let f  = %scan(&feature_cols, &i, %str( ));
        %let vt = %seg_vartype(ds=_sg_dev, var=&f);
        %if &vt = N %then %seg_as_pred_num(f=&f, i=&i, nbins=&numeric_bins);
        %else %seg_as_pred_cat(f=&f, i=&i);
    %end;

    %put NOTE: seg_as_predicates - &sg_npred atomic predicates over &sg_nf features.;

%mend seg_as_predicates;
