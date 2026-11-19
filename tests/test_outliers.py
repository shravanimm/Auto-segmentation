import numpy as np
import pandas as pd

from models.config import OutlierConfig
from utils.outliers import fit_outlier_bounds, clip_to_bounds, flag_outliers, summarize_outliers
from utils.preprocessing import build_feature_matrix


def _frames():
    rng = np.random.default_rng(0)
    dev = pd.DataFrame({
        "skewed": rng.lognormal(3, 0.5, 5000),
        "norm": rng.normal(0, 1, 5000),
        "flag": rng.integers(0, 2, 5000),
    })
    mon = dev.copy()
    mon.loc[:49, "norm"] = 50.0
    return dev, mon


def test_bounds_fit_on_dev_and_skip_discrete():
    dev, mon = _frames()
    fit = fit_outlier_bounds(dev, ["skewed", "norm", "flag"], OutlierConfig())
    assert "flag" not in fit["bounds"]
    lo, hi, _ = fit["bounds"]["norm"]
    assert 2.5 < hi < 6 and -6 < lo < -2.5
    # monitoring spike is detected, dev rate stays small
    s = summarize_outliers(dev, mon, fit)
    f = s["per_feature"].set_index("feature").loc["norm"]
    assert f.mon_outlier_pct >= 0.0099 and f.dev_outlier_pct < 0.01
    assert s["row_level"]["outlier_multivariate"]["mon_pct"] > s["row_level"]["outlier_multivariate"]["dev_pct"]


def test_skewed_feature_not_overflagged():
    dev, _ = _frames()
    fit = fit_outlier_bounds(dev, ["skewed"], OutlierConfig(multivariate=False))
    flags = flag_outliers(dev, fit)
    assert flags["outlier_univariate"].mean() < 0.02


def test_clip_and_feature_matrix_default_unchanged():
    dev, mon = _frames()
    fit = fit_outlier_bounds(dev, ["norm"], OutlierConfig(multivariate=False))
    clipped = clip_to_bounds(mon, fit)
    assert clipped["norm"].max() == fit["bounds"]["norm"][1]
    assert mon["norm"].max() == 50.0  # input not mutated
    X0, _ = build_feature_matrix(mon, ["norm"], [])
    X1, _ = build_feature_matrix(mon, ["norm"], [], fit)
    assert X0["norm"].max() == 50.0 and X1["norm"].max() < 10


def test_dq_outliers_dev_fit_applied_to_monitoring():
    from sas_macros.dq_drift_python_translation import main_wrapper

    dev, mon = _frames()
    dev["customer_id"] = range(len(dev))
    mon["customer_id"] = range(len(mon))
    mon.loc[:299, "norm"] = 50.0  # ~6% spike: well above the +2pp "elevated" rule
    out = main_wrapper(dev, mon, is_dq_req=True, id_cols="customer_id")
    d, m = out["dq_dev"]["outliers"], out["dq_mon"]["outliers"]
    assert "customer_id" not in set(d["name"])
    assert "flag" not in set(d["name"])
    row = m.set_index("name").loc["norm"]
    assert row.status == "elevated" and row.outlier_pct > row.baseline_outlier_pct
    assert (d["status"] != "elevated").all()
    assert len(out["dq_mon"]["outlier_rows"]) == 2


def test_valid_range_override():
    from sas_macros.dq_drift_python_translation import main_wrapper

    dev, mon = _frames()
    dev["age"] = np.random.default_rng(1).integers(21, 76, len(dev)).astype(float)
    mon["age"] = dev["age"]
    mon.loc[:9, "age"] = 5.0
    out = main_wrapper(dev, mon, is_dq_req=True, valid_ranges={"age": (18, 100), "flag": (0, 1)})
    d = out["dq_dev"]["outliers"].set_index("name")
    m = out["dq_mon"]["outliers"].set_index("name")
    assert d.loc["age", "lower_bound"] >= 18 and d.loc["age", "upper_bound"] <= 100
    assert "valid_range" in d.loc["age", "method"]
    assert m.loc["age", "range_violations"] == 10 and m.loc["age", "status"] == "range_violation"
    assert d.loc["age", "range_violations"] == 0
    assert d.loc["flag", "method"] == "valid_range"  # discrete column still gets its rule
