"""
export_golden.py
================
Runs the existing Python techniques ONCE with the benchmark settings of
compare_segmentation_techniques.py and writes the reference ("golden") files the
SAS port is diffed against (see ../seg_execute.sas):

    golden_<tech>_pool.csv   every candidate that reached severity scoring
                             (AutoSlicer, Drift Tree, Gradient Boosting)
    golden_<tech>_top.csv    final top-N with public column names (all five)
    golden_params.json       the settings used

<tech> = autoslicer | drift_tree | gradient_boosting | kmeans | feature_binning
Usage (from the repo root):
    python sas_macros/parity/export_golden.py [out_dir]
"""
from __future__ import annotations
import contextlib, io, json, os, sys, warnings
warnings.filterwarnings("ignore")
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

import pandas as pd
from compare_segmentation_techniques import build_feature_schema
from models.config import SlicerConfig, DLTConfig, GBConfig, KMeansConfig, FeatureBinningConfig
import techniques.autoslicer as az
import techniques.drift_tree as dt
import techniques.gradient_boosting as gb
import techniques.kmeans as km
import techniques.feature_binning as fb

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "golden")
os.makedirs(OUT, exist_ok=True)
DEV, MON = "data/development_data_5000_shap.csv", "data/monitoring_data_5000_shap.csv"
dev, mon = pd.read_csv(DEV), pd.read_csv(MON)
schema = build_feature_schema(dev)


def run_capturing(module, technique_cls, cfg, tag):
    """Run a technique, capturing the scored pool handed to compute_severity_scores."""
    captured = {}
    orig = getattr(module, "compute_severity_scores", None)   # Feature Binning has its own scoring

    def _capture(evaluated, **kw):
        out = orig(evaluated, **kw)
        captured["pool"] = pd.DataFrame(
            [{k: v for k, v in r.items() if k not in ("_mon_mask", "combo")} for r in out])
        return out

    if orig is not None:
        module.compute_severity_scores = _capture
    try:
        with contextlib.redirect_stdout(io.StringIO()):          # evaluate_segment prints debug blocks
            res = technique_cls().run(dev, mon, config=cfg)
    finally:
        if orig is not None:
            module.compute_severity_scores = orig
    if "pool" in captured:
        captured["pool"].to_csv(os.path.join(OUT, f"golden_{tag}_pool.csv"), index=False)
    res.segments_df.to_csv(os.path.join(OUT, f"golden_{tag}_top.csv"), index=False)
    n_pool = len(captured["pool"]) if "pool" in captured else None
    print(f"{tag:20s} pool={n_pool} returned={len(res.segments_df)}")
    return n_pool, len(res.segments_df)


params = {"dev": DEV, "mon": MON}
cfgs = {
    "autoslicer": (az, az.AutoSlicerTechnique, SlicerConfig(schema=schema, max_combo_depth=2, beam_width=10)),
    "drift_tree": (dt, dt.DriftLocalizationTreeTechnique, DLTConfig(schema=schema, max_depth=4, min_samples_leaf=0.04)),
    "gradient_boosting": (gb, gb.GradientBoostingSegmentationTechnique, GBConfig(schema=schema, n_estimators=50, max_depth=3)),
    "kmeans": (km, km.KMeansSegmentationTechnique, KMeansConfig(schema=schema, k_range=range(8, 13), min_cluster_pct=0.02)),
    "feature_binning": (fb, fb.FeatureBinningTechnique, FeatureBinningConfig(schema=schema)),
}
for tag, (mod, cls, cfg) in cfgs.items():
    n_pool, n_ret = run_capturing(mod, cls, cfg, tag)
    params[tag] = {"pool": n_pool, "returned": n_ret,
                   "config": {k: (list(v) if isinstance(v, range) else v) for k, v in vars(cfg).items()
                              if k not in ("schema", "outlier") and isinstance(v, (int, float, str, bool, range, type(None)))}}
with open(os.path.join(OUT, "golden_params.json"), "w") as fh:
    json.dump(params, fh, indent=2, default=str)
print("->", OUT)
