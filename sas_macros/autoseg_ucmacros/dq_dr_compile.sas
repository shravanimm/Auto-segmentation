/* ============================================================================
   dq_dr_compile.sas
   Compiles every DQ/DD macro in this folder, in one shot. %include order does
   not matter here - every file is a %macro/%mend definition with no immediate
   execution, so nothing runs until csb_dq_dr_calc_wrapper is actually called
   (from dq_dr_execute.sas) after all of these have been compiled.

   On SAS Viya / SAS Content, this whole file can be replaced by pointing a
   filesrvc fileref at this folder and doing a single %include on it, e.g.:

       filename dq_dr filesrvc folderpath="/Public/AutoSegmentation/autoseg_ucmacros";
       %include dq_dr;

   which compiles every .sas file in the folder in one step. The explicit
   %include list below is the portable equivalent for local/base-SAS use and
   for keeping this folder under version control.

   Requires the caller to set &_autoseg_ucmacros to this folder's path before
   including this file (dq_dr_execute.sas does this) - e.g.:
       %let _autoseg_ucmacros = /path/to/autosegmentation/sas_macros/autoseg_ucmacros;
       %include "&_autoseg_ucmacros/dq_dr_compile.sas";

   Included by: dq_dr_execute.sas (the single file to run)
   ============================================================================ */

%include "&_autoseg_ucmacros/dq_foundational_profiling.sas";
%include "&_autoseg_ucmacros/dq_blockers.sas";
%include "&_autoseg_ucmacros/dq_governance.sas";
%include "&_autoseg_ucmacros/dq_healthscore.sas";
%include "&_autoseg_ucmacros/dq_calc_wrapper.sas";

%include "&_autoseg_ucmacros/drift_schema.sas";
%include "&_autoseg_ucmacros/drift_completeness.sas";
%include "&_autoseg_ucmacros/drift_psi_one_feature.sas";
%include "&_autoseg_ucmacros/drift_csi.sas";
%include "&_autoseg_ucmacros/drift_score_psi.sas";
%include "&_autoseg_ucmacros/drift_target_bad_rate.sas";
%include "&_autoseg_ucmacros/drift_distribution_stats.sas";
%include "&_autoseg_ucmacros/drift_entropy.sas";
%include "&_autoseg_ucmacros/drift_ks_one_feature.sas";
%include "&_autoseg_ucmacros/drift_ks.sas";
%include "&_autoseg_ucmacros/drift_categorical_psi_one_feature.sas";
%include "&_autoseg_ucmacros/drift_categorical_psi.sas";
%include "&_autoseg_ucmacros/drift_calc_wrapper.sas";

%include "&_autoseg_ucmacros/csb_dq_dr_calc_wrapper.sas";

%put NOTE: All DQ/DD macros compiled from &_autoseg_ucmacros;
