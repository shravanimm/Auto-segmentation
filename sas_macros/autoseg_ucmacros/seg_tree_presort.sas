/* ============================================================================
   seg_tree_presort.sas
   Sorts the tree matrix once per feature: _trs<j>(_tid, x<j>) ascending in x<j>.
   Reused by every node/level of seg_tree_fit - and by every one of the 50-150
   trees of Gradient Boosting, because the features never change between trees.
   ============================================================================ */
%macro seg_tree_presort(data=, p=);
    %local j;
    %do j = 1 %to &p;
        proc sort data=&data(keep=_tid x&j) out=_trs&j;
            by x&j _tid;
        run;
    %end;
%mend seg_tree_presort;
