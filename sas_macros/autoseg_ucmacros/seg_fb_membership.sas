/* ============================================================================
   seg_fb_membership.sas
   Writes _sg_memb_dev / _sg_memb_mon (cand_id = bin_id, _rid) for every Feature
   Binning bin (bin_mask / _single_condition_mask):
     missing     : the feature is missing
     numeric     : not missing and lower < x <= upper   (open ends = infinite)
     categorical : value (missing -> '__MISSING__') is one of the bin's categories
   Bins of one feature are disjoint, so a row matches at most one bin per feature.
   Needs _fb_bin and _fb_cat; feature types are read from the data.
   ============================================================================ */
%macro seg_fb_membership(feature_cols=);

    %local nf i f vt side tab out nb;

    data _sg_memb_dev; length cand_id 8 _rid 8; stop; run;
    data _sg_memb_mon; length cand_id 8 _rid 8; stop; run;

    %let nf = %sysfunc(countw(&feature_cols, %str( )));
    %do i = 1 %to &nf;
        %let f = %scan(&feature_cols, &i, %str( ));
        %let vt = %seg_vartype(ds=_sg_dev, var=&f);

        proc sql noprint; select count(*) into :nb trimmed from _fb_bin where feature = "&f"; quit;
        %if &nb > 0 %then %do;
            %do side = 1 %to 2;
                %if &side = 1 %then %do; %let tab = _sg_dev; %let out = _sg_memb_dev; %end;
                %else %do; %let tab = _sg_mon; %let out = _sg_memb_mon; %end;

                %if &vt = N %then %do;
                    data _fb_mm(keep=cand_id _rid);
                        array bid [40] _temporary_;
                        array blo [40] _temporary_;
                        array bhi [40] _temporary_;
                        array bli [40] _temporary_;
                        array bhn [40] _temporary_;
                        array bty [40] $10 _temporary_;
                        if _n_ = 1 then do;
                            nb = 0;
                            do until(_e);
                                set _fb_bin(where=(feature = "&f")) end=_e;
                                nb + 1;
                                bid[nb] = bin_id; blo[nb] = lower; bhi[nb] = upper;
                                bli[nb] = lo_inf; bhn[nb] = hi_inf; bty[nb] = btype;
                            end;
                        end;
                        set &tab(keep=_rid &f);
                        do _k = 1 to nb;
                            if bty[_k] = 'missing' then do;
                                if missing(&f) then do; cand_id = bid[_k]; output; end;
                            end;
                            else if not missing(&f) then do;
                                if (bli[_k] or &f > blo[_k]) and (bhn[_k] or &f <= bhi[_k]) then do;
                                    cand_id = bid[_k]; output;
                                end;
                            end;
                        end;
                    run;
                %end;
                %else %do;
                    proc sql;
                        create table _fb_cat1 as
                        select c.bin_id, c.value from _fb_cat c, _fb_bin b
                        where c.bin_id = b.bin_id and b.feature = "&f";
                    quit;
                    data _fb_mm(keep=cand_id _rid);
                        length value $200;
                        if _n_ = 1 then do;
                            declare hash hc(dataset: "_fb_cat1");
                            hc.defineKey('value');
                            hc.defineData('bin_id');
                            hc.defineDone();
                            call missing(bin_id);
                        end;
                        set &tab(keep=_rid &f);
                        value = coalescec(strip(&f), '__MISSING__');
                        if hc.find() = 0 then do; cand_id = bin_id; output; end;
                    run;
                %end;
                proc append base=&out data=_fb_mm force; run;
            %end;
        %end;
    %end;

%mend seg_fb_membership;
