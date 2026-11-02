/* ============================================================================
   seg_f32.sas
   DATA-step statement macro: rounds a double to IEEE single precision with
   round-to-nearest-even, exactly what numpy/scikit-learn do when they cast X to
   float32 before fitting/applying a tree.
   Do NOT use put(x, rb4.) / input(.., rb4.) for this: SAS's 4-byte real format
   TRUNCATES the mantissa instead of rounding (differs from numpy for ~48% of
   values), which moves tree thresholds by one float32 ulp and flips display
   rounding such as 40.315 -> 40.31 instead of 40.32.
   Usage inside a DATA step:   %seg_f32(x=<double expr var>, into=<result var>)
   ============================================================================ */
%macro seg_f32(x=, into=);
    if missing(&x) or &x = 0 then &into = &x;
    else do;
        _f3a = abs(&x);
        _f3e = floor(log2(_f3a));
        if 2 ** _f3e > _f3a then _f3e = _f3e - 1;
        else if 2 ** (_f3e + 1) <= _f3a then _f3e = _f3e + 1;
        _f3u = 2 ** (_f3e - 23);
        _f3y = _f3a / _f3u;
        _f3r = floor(_f3y + 0.5);
        if (_f3y + 0.5) = _f3r and mod(_f3r, 2) = 1 then _f3r = _f3r - 1;
        &into = sign(&x) * _f3r * _f3u;
    end;
%mend seg_f32;
