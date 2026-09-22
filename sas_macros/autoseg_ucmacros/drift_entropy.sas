/* ============================================================================
   drift_entropy.sas
   (was %drift_tech7_entropy in the old 20_drift_macros.sas)

   Entropy Drift for categorical columns: Shannon entropy of the category-
   frequency distribution, dev vs mon. Rising entropy = diversity increasing
   (categories spreading out); falling = concentrating into fewer categories.

   Called by: drift_calc_wrapper.sas
   ============================================================================ */
%macro drift_entropy(dev=, mon=, out=, categorical_cols=);

    %local nvars i v dev_n mon_n dev_h mon_h;
    %let nvars = %sysfunc(countw(&categorical_cols));

    data &out;
        length feature $32;
        dev_entropy = .; mon_entropy = .; entropy_delta = .;
        stop;
    run;

    %do i = 1 %to &nvars;
        %let v = %scan(&categorical_cols, &i);

        proc freq data=&dev noprint;
            tables &v / out=_ent_dev_(keep=&v count);
        run;
        proc freq data=&mon noprint;
            tables &v / out=_ent_mon_(keep=&v count);
        run;

        proc sql noprint;
            select sum(count) into :dev_n trimmed from _ent_dev_;
            select sum(count) into :mon_n trimmed from _ent_mon_;
        quit;

        data _ent_dev_calc_;
            set _ent_dev_;
            p = count / &dev_n;
            h_term = -p * log2(p);
        run;
        data _ent_mon_calc_;
            set _ent_mon_;
            p = count / &mon_n;
            h_term = -p * log2(p);
        run;

        proc sql noprint;
            select sum(h_term) into :dev_h trimmed from _ent_dev_calc_;
            select sum(h_term) into :mon_h trimmed from _ent_mon_calc_;
        quit;

        proc sql;
            insert into &out
            values("&v", %sysfunc(round(&dev_h,0.0001)), %sysfunc(round(&mon_h,0.0001)),
                   %sysfunc(round(%sysevalf(&mon_h - &dev_h),0.0001)));
        quit;
    %end;

    proc datasets lib=work nolist;
        delete _ent_dev_ _ent_mon_ _ent_dev_calc_ _ent_mon_calc_;
    quit;

%mend drift_entropy;
