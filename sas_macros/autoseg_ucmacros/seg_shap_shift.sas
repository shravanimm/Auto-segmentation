/* ============================================================================
   seg_shap_shift.sas
   mean_shap_shift per candidate = mean over shap columns of
   |mean_mon(shap) - mean_dev(shap)| inside the segment (core/candidate_
   evaluation.py; feeds the 0.15-weight SHAP term of the Root Cause Score).
   No shap columns => 0.
   NOT ported here: Top_SHAP_Feature / Top_SHAP_PSI (diagnostic output columns
   only; they do not enter any score).
   cnt : table with cand_id        out: cand_id, mean_shap_shift
   ============================================================================ */
%macro seg_shap_shift(mem_dev=, mem_mon=, shap_cols=, cnt=, out=);

    %local n i;
    %let n = %sysfunc(countw(&shap_cols, %str( )));

    %if &n = 0 %then %do;
        data &out;
            set &cnt(keep=cand_id);
            mean_shap_shift = 0;
        run;
    %end;
    %else %do;
        proc sql;
            create table _sg_shd as
            select cand_id %do i = 1 %to &n; , avg(%scan(&shap_cols, &i, %str( ))) as d&i %end;
            from &mem_dev group by cand_id order by cand_id;

            create table _sg_shm as
            select cand_id %do i = 1 %to &n; , avg(%scan(&shap_cols, &i, %str( ))) as m&i %end;
            from &mem_mon group by cand_id order by cand_id;
        quit;

        data &out(keep=cand_id mean_shap_shift);
            merge _sg_shd _sg_shm;
            by cand_id;
            array dd [&n] d1-d&n;
            array mm [&n] m1-m&n;
            _s = 0; _c = 0;
            do _i = 1 to &n;
                if not missing(dd[_i]) and not missing(mm[_i]) then do;
                    _s = _s + abs(mm[_i] - dd[_i]);
                    _c = _c + 1;
                end;
            end;
            mean_shap_shift = ifn(_c > 0, _s / _c, 0);
        run;
    %end;

%mend seg_shap_shift;
