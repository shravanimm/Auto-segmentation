"""
export_trend_golden.py - reference results for the SAS trend macros.

Builds a reproducible synthetic multi-period history (6 periods, 3 techniques, segments that recur
with different patterns), then runs the PYTHON implementation (core/multi_period_analysis.py):
  compute_trend_metrics -> golden_trend_summary.csv
  build_segment_time_series -> golden_trend_history.csv  (the appearance table = SAS history input)
  forecast_segment_scores -> golden_trend_forecast.csv
  golden_trend_periods.csv   (Period_Index, Period)
The SAS script seg_execute_trend_viya.sas feeds golden_trend_history.csv to seg_trend_metrics /
seg_trend_forecast and compares the results.

Run from the repo root:  python sas_macros/parity/export_trend_golden.py
"""
import os
import sys

import numpy as np
import pandas as pd

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, ROOT)

from core.multi_period_analysis import (  # noqa: E402
    _build_period_appearance_long_df, build_segment_time_series, compute_trend_metrics,
    forecast_segment_scores)
from models.config import TrendAnalysisConfig  # noqa: E402

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "golden")
os.makedirs(OUT, exist_ok=True)

rng = np.random.default_rng(2026)
PERIODS = ["2026-01", "2026-02", "2026-03", "2026-04", "2026-05", "2026-06"]
TECHS = ["AutoSlicer", "Drift Localization Tree", "Gradient Boosting"]
N_SEG = 16          # segments per technique; each appears in a random subset of periods


def make_period(period_idx):
    rows = []
    for t_i, tech in enumerate(TECHS):
        for s in range(N_SEG):
            # recurring pattern: segment s appears when a hashed rule says so, so some recur
            # every period, some only early, some only late, some on and off
            pattern = (s * 7 + t_i * 3 + period_idx * (s % 4)) % 5
            if s % 5 == 0 or pattern in (0, 1, 2):
                base = 0.2 + 0.04 * (s % 6) + 0.02 * period_idx * (1 if s % 3 else -0.5)
                rcs = float(np.clip(base + rng.normal(0, 0.03), 0.01, 0.98))
                sis = float(abs(rng.normal(0.4 + 0.2 * rcs, 0.1)))
                dis = float(abs(rng.normal(0.3 + 0.2 * rcs, 0.1)))
                rows.append({
                    "Technique": tech,
                    "Segment_Definition": f"{tech[:2]}_seg_{s:02d} (feat_{s % 5} > {s})",
                    "Severity_Score": round(rcs * 20, 4),
                    "Root_Cause_Score": rcs,
                    "SIS_Raw": sis, "DIS_Raw": dis,
                    "mean_feature_psi": float(abs(rng.normal(0.1 + 0.1 * rcs, 0.05))),
                    "mean_shap_shift": float(abs(rng.normal(0.05 + 0.05 * rcs, 0.02))),
                    "Dev_Pct": 0.05, "Mon_Pct": float(0.05 + 0.01 * s % 7),
                    "Rank": len(rows) + 1,
                })
    return pd.DataFrame(rows)


period_results = {p: make_period(i) for i, p in enumerate(PERIODS)}
cfg = TrendAnalysisConfig()

long_df, periods = _build_period_appearance_long_df(period_results, cfg.n_worst)
history = build_segment_time_series(period_results, cfg)
# SAS history input: appearance rows with every column the macros read
keep = ["Technique", "Segment_Definition", "Period", "Period_Index", "Severity_Score",
        "Root_Cause_Score", "SIS_Raw", "DIS_Raw", "mean_feature_psi", "mean_shap_shift"]
hist_out = long_df[keep].sort_values(["Technique", "Segment_Definition", "Period_Index"])
summary = compute_trend_metrics(period_results, cfg)
forecast = forecast_segment_scores(history, cfg)

hist_out.to_csv(os.path.join(OUT, "golden_trend_history.csv"), index=False)
pd.DataFrame({"Period_Index": range(len(periods)), "Period": periods}).to_csv(
    os.path.join(OUT, "golden_trend_periods.csv"), index=False)
sum_cols = ["Technique", "Segment_Definition", "Periods_Appeared", "Total_Periods", "Appeared_In",
            "Frequency", "Recency_Factor", "Consistency_Score", "Trend_Impact_Score", "SIS_Raw",
            "SIS_Trend", "Root_Cause_Score_Trend", "Severity_Score_Trend"]
summary[sum_cols].to_csv(os.path.join(OUT, "golden_trend_summary.csv"), index=False)
forecast.to_csv(os.path.join(OUT, "golden_trend_forecast.csv"), index=False)

print("history rows:", len(hist_out), "| summary rows:", len(summary), "| forecast rows:", len(forecast),
      "| early warnings:", int(forecast["Early_Warning"].sum()) if len(forecast) else 0,
      "| segments with 2 points:", int((forecast["Periods_Used"] == 2).sum()) if len(forecast) else 0)
