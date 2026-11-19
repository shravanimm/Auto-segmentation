/* ============================================================================
   rm_kpi_local_test.sas  -  test the Risk Modeling KPI adapter in SAS Studio BEFORE pasting into RM.

   It FAKES what Risk Modeling provides (the predefined m_* macro variables, the scored data set,
   the KPI output table) using the demo data, then calls the same code each KPI's Code tab will call.
   Expected: a table with 5 rows (one per KPI id) and m_kpi_calc_success_flg = Y.
   Run section by section.
   ============================================================================ */
options obs=max nosyntaxcheck;
%let syscc=0;
%let base = /Users/sastest1/My Folder/autoseg;          /* <-- your SAS Content folder */
filename segmac filesrvc folderpath="&base/macros";
%include segmac(seg_compile_viya.sas);
%include segmac(csb_rm_kpi_segmentation.sas);

/* ---- SECTION 1: the data that Risk Modeling would provide ---- */
filename devcsv filesrvc folderpath="&base/data" filename="development_data_5000_shap.csv";
filename moncsv filesrvc folderpath="&base/data" filename="monitoring_data_5000_shap.csv";
proc import datafile=devcsv out=work.rm_scored_dev dbms=csv replace; getnames=yes; guessingrows=max; run;
proc import datafile=moncsv out=work.rm_scored_mon dbms=csv replace; getnames=yes; guessingrows=max; run;
data work.rm_out; length KPI_ID $64 KPI_VALUE 8; stop; run;     /* the KPI output table */

/* predefined macro variables (RM assigns these before running the KPI code) */
%let m_model_id = 1;
%let m_output_cas_libref = WORK;
%let m_kpi_value_otpt_cas_tbl_nm = rm_out;
%let m_act_result_col_name = default_flag;
%let m_est_result_col_name = pd_score;
%let m_kpi_calc_success_flg = Y;

/* what the KPI code sets itself */
%let sg_rm_ref_libref = WORK;            /* in RM use a persistent library */
%let sg_rm_exclude_cols = lgd_actual;

/* ---- SECTION 2: development run (DD) - saves the development reference ---- */
%let m_run_type_cd = DD;
%let m_scored_ds_libref_kpi_calc = WORK;
%let m_scored_ds_nm_kpi_calc = rm_scored_dev;
%csb_rm_kpi_segmentation(kpi_id=rca_max_gini_drop, metric=rca_max_gini_drop);
%put m_kpi_calc_success_flg = &m_kpi_calc_success_flg;

/* ---- SECTION 3: ongoing run (ONG) - one call per KPI, exactly like the five Code tabs ---- */
%let m_run_type_cd = ONG;
%let m_scored_ds_nm_kpi_calc = rm_scored_mon;
%csb_rm_kpi_segmentation(kpi_id=rca_max_gini_drop, metric=rca_max_gini_drop);
%csb_rm_kpi_segmentation(kpi_id=rca_max_ks_drop, metric=rca_max_ks_drop);
%csb_rm_kpi_segmentation(kpi_id=rca_max_badrate_rise, metric=rca_max_badrate_rise);
%csb_rm_kpi_segmentation(kpi_id=rca_max_segment_psi, metric=rca_max_segment_psi);
%csb_rm_kpi_segmentation(kpi_id=rca_n_deteriorating, metric=rca_n_deteriorating);
%csb_rm_kpi_segmentation(kpi_id=rca_max_sis, metric=rca_max_sis);
%csb_rm_kpi_segmentation(kpi_id=rca_max_dis, metric=rca_max_dis);
%csb_rm_kpi_segmentation(kpi_id=rca_max_business_impact, metric=rca_max_business_impact);
%csb_rm_kpi_segmentation(kpi_id=rca_max_portfolio_impact, metric=rca_max_portfolio_impact);
%csb_rm_kpi_segmentation(kpi_id=rca_n_significant, metric=rca_n_significant);
%csb_rm_kpi_segmentation(kpi_id=rca_max_feature_drift, metric=rca_max_feature_drift);
%csb_rm_kpi_segmentation(kpi_id=rca_max_shap_shift, metric=rca_max_shap_shift);
%csb_rm_kpi_segmentation(kpi_id=rca_max_exposure_drift, metric=rca_max_exposure_drift);
%csb_rm_kpi_segmentation(kpi_id=rca_max_calibration_drift, metric=rca_max_calibration_drift);
%csb_rm_kpi_segmentation(kpi_id=rca_max_ece_rise, metric=rca_max_ece_rise);
/* trend KPIs: need a scored data set with several periods and  %let sg_rm_period_col = <column>;  (not part of this
   single-period test) */

title "KPI output table (what Risk Modeling would store)";
proc print data=work.rm_out noobs; run;
title;
