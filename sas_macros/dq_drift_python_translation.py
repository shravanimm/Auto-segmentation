"""
dq_drift_python_translation.py
================================================================================
Standalone Python (pandas/numpy) translation of the SAS Data Quality and Data
Drift macros in this project:

    dq_dr_execute.sas                        <- the one file that runs everything
    autoseg_ucmacros/csb_dq_dr_calc_wrapper.sas
    autoseg_ucmacros/dq_*.sas                 (4 files - Data Quality)
    autoseg_ucmacros/drift_*.sas              (13 files - Data Drift)

(Function names below still use the pre-refactor macro names - e.g.
dq_tech1_profile, drift_tech3_csi - from when this was one 10_dq_macros.sas /
20_drift_macros.sas file each. The SAS side has since been split one-macro-
per-file and renamed (dq_tech1_profile -> dq_foundational_profiling,
drift_tech5_target -> drift_target_bad_rate, main_wrapper ->
csb_dq_dr_calc_wrapper, etc.) for better engineering hygiene; the formulas and
this file's function names are unchanged, so match by formula/position rather
than by exact name when diffing against the current .sas files.)

This is the live implementation behind streamlit_app.py's Home tab (Data
Quality / Data Drift checkboxes) via main_wrapper() below — not just a
reference/fallback. It also doubles as a standalone reference so the same
DQ/DD logic can be shown, run, or handed over independent of the SAS/Viya
environment if anyone needs it.

Every function below mirrors one SAS macro (see the mapping above), using the
exact same formulas, default thresholds, and column names as the .sas source,
so the two can be diffed side by side. Where pandas/numpy cannot reproduce a
SAS behaviour exactly, that divergence is called out in a comment at the point
it happens rather than silently approximated.

Requires: pandas, numpy (both already used elsewhere in this project).
"""

from __future__ import annotations

import math
from typing import Optional, Sequence, Union

import numpy as np
import pandas as pd

ColumnList = Optional[Union[str, Sequence[str]]]


def _split_cols(cols: ColumnList) -> list:
    """SAS macro params like id_cols=/private_cols= are space-separated strings
    matched case-insensitively via indexw(upcase(...)). Accept either a
    space-separated string or a list/tuple here for convenience."""
    if not cols:
        return []
    if isinstance(cols, str):
        return [c.upper() for c in cols.split()]
    return [str(c).upper() for c in cols]


# ============================================================================
# 10_dq_macros.sas -> Data Quality
# ============================================================================

def dq_tech1_profile(df: pd.DataFrame) -> pd.DataFrame:
    """<-> %dq_tech1_profile. One row per column: completeness, cardinality,
    uniqueness, mean/std/min/max/skew/kurtosis/quantiles, IQR outlier count.

    Note: pandas' Series.skew() / Series.kurt() use the same bias-corrected
    (excess) moment formulas as SAS PROC MEANS skew=/kurtosis=, so these are
    numerically equivalent to the SAS output, not an approximation.
    """
    nobs = len(df)
    rows = []

    for name in df.columns:
        col = df[name]
        is_numeric = pd.api.types.is_numeric_dtype(col)
        vtype = 1 if is_numeric else 2  # mirrors PROC CONTENTS type: 1=numeric, 2=char

        nmiss = int(col.isna().sum())
        card = int(col.nunique(dropna=True))

        completeness_pct = 100.0 * (1 - nmiss / nobs) if nobs else 0.0
        uniqueness_pct = 100.0 * card / max(nobs - nmiss, 1)

        mean = std = vmin = vmax = skew = kurt = q25 = q50 = q75 = np.nan
        n_outliers = 0

        if is_numeric:
            valid = col.dropna()
            if len(valid) > 0:
                mean = float(valid.mean())
                std = float(valid.std())  # ddof=1, matches PROC MEANS default
                vmin = float(valid.min())
                vmax = float(valid.max())
                q25 = float(valid.quantile(0.25))
                q50 = float(valid.quantile(0.50))
                q75 = float(valid.quantile(0.75))
            if len(valid) > 3:
                skew = float(valid.skew())
                kurt = float(valid.kurt())

            iqr = q75 - q25
            lobnd = q25 - 1.5 * iqr
            hibnd = q75 + 1.5 * iqr
            n_outliers = int(((valid < lobnd) | (valid > hibnd)).sum())

        rows.append({
            "name": name, "type": vtype, "cardinality_count": card, "missing_count": nmiss,
            "completeness_pct": completeness_pct, "uniqueness_pct": uniqueness_pct,
            "mean": mean, "std": std, "min": vmin, "max": vmax,
            "skewness": skew, "kurtosis": kurt,
            "q25": q25, "q50": q50, "q75": q75, "n_outliers": n_outliers,
        })

    return pd.DataFrame(rows)


def dq_tech2_blockers(profile: pd.DataFrame, missing_thresh: float = 50) -> pd.DataFrame:
    """<-> %dq_tech2_blockers. high_missing / zero_variance blocker rules."""
    rows = []
    for _, r in profile.iterrows():
        if r["completeness_pct"] < missing_thresh:
            rows.append({
                "name": r["name"], "rule": "high_missing",
                "detail": f"{r['completeness_pct']:.1f}% complete - {int(r['missing_count'])} rows missing",
            })
        if r["cardinality_count"] <= 1:
            rows.append({
                "name": r["name"], "rule": "zero_variance",
                "detail": f"Only {int(r['cardinality_count'])} unique value(s) - zero predictive signal",
            })
    return pd.DataFrame(rows, columns=["name", "rule", "detail"])


def dq_tech3_governance(profile: pd.DataFrame, id_cols: ColumnList = None,
                         private_cols: ColumnList = None, target_col: Optional[str] = None,
                         id_uniqueness_thresh: float = 99.9,
                         leakage_card_min: float = 50) -> pd.DataFrame:
    """<-> %dq_tech3_governance. IDENTIFIER / LEAKAGE / PRIVACY governance flags."""
    id_set = set(_split_cols(id_cols))
    private_set = set(_split_cols(private_cols))
    target_up = target_col.upper() if target_col else None

    rows = []
    for _, r in profile.iterrows():
        name = r["name"]
        name_up = str(name).upper()

        if r["uniqueness_pct"] >= id_uniqueness_thresh or name_up in id_set:
            rows.append({
                "name": name, "risk_type": "IDENTIFIER",
                "detail": f"Uniqueness {r['uniqueness_pct']:.1f}% - surrogate key, exclude from features",
            })

        if (r["type"] == 1 and pd.notna(r["min"]) and pd.notna(r["max"])
                and r["min"] >= 0 and r["max"] <= 1
                and r["cardinality_count"] >= leakage_card_min
                and (target_up is None or name_up != target_up)):
            rows.append({
                "name": name, "risk_type": "LEAKAGE",
                "detail": "Bounded [0,1], high cardinality - resembles a model probability output",
            })

        if name_up in private_set:
            rows.append({
                "name": name, "risk_type": "PRIVACY",
                "detail": "Listed as a privacy-sensitive attribute",
            })

    return pd.DataFrame(rows, columns=["name", "risk_type", "detail"])


def dq_tech4_healthscore(profile: pd.DataFrame, blockers: pd.DataFrame, governance: pd.DataFrame,
                          w_completeness: float = 0.35, w_variance: float = 0.25,
                          w_governance: float = 0.25, w_distribution: float = 0.15):
    """<-> %dq_tech4_healthscore. Weighted 0-100 per-column score + dataset
    readiness score (mean of column scores). Returns (health_df, readiness_score)."""
    blocked_names = set(blockers["name"]) if len(blockers) else set()
    governed_names = set(governance["name"]) if len(governance) else set()

    rows = []
    for _, p in profile.iterrows():
        name = p["name"]
        is_blocked = name in blocked_names
        is_governed = name in governed_names

        completeness_score = p["completeness_pct"] / 100.0
        variance_score = 1.0 if p["cardinality_count"] > 1 else 0.0
        governance_score = 1 - 0.6 * (1.0 if is_governed else 0.0)
        distribution_score = 1.0 if (p["type"] != 1 or abs(p["skewness"] if pd.notna(p["skewness"]) else 0) < 1) else 0.0

        if is_blocked:
            health_score = 0.0
        else:
            health_score = round(100 * (
                w_completeness * completeness_score
                + w_variance * variance_score
                + w_governance * governance_score
                + w_distribution * distribution_score
            ), 1)

        status = "drop" if is_blocked else ("caution" if is_governed else "ready")

        rows.append({
            "name": name,
            "completeness_score": completeness_score, "variance_score": variance_score,
            "governance_score": governance_score, "distribution_score": distribution_score,
            "health_score": health_score, "status": status,
        })

    health = pd.DataFrame(rows)
    readiness_score = round(float(health["health_score"].mean()), 1) if len(health) else 0.0
    return health, readiness_score


def dq_calc_wrapper(df: pd.DataFrame, target_col: Optional[str] = None,
                     id_cols: ColumnList = None, private_cols: ColumnList = None,
                     missing_thresh: float = 50, id_uniqueness_thresh: float = 99.9,
                     leakage_card_min: float = 50) -> dict:
    """<-> %dq_calc_wrapper. Orchestrates the 4 DQ techniques for one dataset."""
    profile = dq_tech1_profile(df)
    blockers = dq_tech2_blockers(profile, missing_thresh=missing_thresh)
    governance = dq_tech3_governance(profile, id_cols=id_cols, private_cols=private_cols,
                                      target_col=target_col,
                                      id_uniqueness_thresh=id_uniqueness_thresh,
                                      leakage_card_min=leakage_card_min)
    health, readiness_score = dq_tech4_healthscore(profile, blockers, governance)

    return {
        "profile": profile, "blockers": blockers, "governance": governance,
        "health": health, "readiness_score": readiness_score,
    }


# ============================================================================
# 20_drift_macros.sas -> Data Drift
# ============================================================================

def drift_tech1_schema(dev: pd.DataFrame, mon: pd.DataFrame) -> pd.DataFrame:
    """<-> %drift_tech1_schema. added / dropped / type_changed / unchanged.

    Divergence from SAS: PROC CONTENTS also flags a length change (e.g. a
    character column shrinking from $20 to $8) as type_changed. Pandas has no
    equivalent fixed-length metadata for object columns, so this only compares
    numeric-vs-character dtype kind, not stored length.
    """
    dev_cols = {c: ("numeric" if pd.api.types.is_numeric_dtype(dev[c]) else "char") for c in dev.columns}
    mon_cols = {c: ("numeric" if pd.api.types.is_numeric_dtype(mon[c]) else "char") for c in mon.columns}

    dev_up = {c.upper(): c for c in dev_cols}
    mon_up = {c.upper(): c for c in mon_cols}
    all_up = sorted(set(dev_up) | set(mon_up))

    rows = []
    for key in all_up:
        d_name = dev_up.get(key)
        m_name = mon_up.get(key)
        d_type = dev_cols.get(d_name) if d_name else None
        m_type = mon_cols.get(m_name) if m_name else None

        if d_name is None:
            change_type = "added"
        elif m_name is None:
            change_type = "dropped"
        elif d_type != m_type:
            change_type = "type_changed"
        else:
            change_type = "unchanged"

        rows.append({
            "name": d_name if d_name is not None else m_name,
            "change_type": change_type, "dev_type": d_type, "mon_type": m_type,
        })

    return pd.DataFrame(rows)


def drift_tech2_completeness(dev: pd.DataFrame, mon: pd.DataFrame, delta_alert: float = 5) -> pd.DataFrame:
    """<-> %drift_tech2_completeness. Missing% delta for columns present in both."""
    devn, monn = len(dev), len(mon)
    common = [c for c in dev.columns if c.upper() in {m.upper() for m in mon.columns}]

    rows = []
    for v in common:
        dev_pct = 100.0 * (1 - dev[v].isna().sum() / devn) if devn else 0.0
        mon_pct = 100.0 * (1 - mon[v].isna().sum() / monn) if monn else 0.0
        delta = mon_pct - dev_pct

        if delta <= -delta_alert:
            pattern = "growing_missing"
        elif delta >= delta_alert:
            pattern = "recovering"
        else:
            pattern = "stable_missing"

        rows.append({
            "name": v, "dev_completeness_pct": dev_pct, "mon_completeness_pct": mon_pct,
            "delta_pp": delta, "pattern": pattern,
        })

    return pd.DataFrame(rows)


def _psi_one_feature(dev: pd.Series, mon: pd.Series, psi_stable: float = 0.10, psi_shift: float = 0.25):
    """<-> %_psi_one_feature. Real 10-bucket PSI: dev's own decile cutpoints,
    both dev and mon counted into those same fixed boundaries.

    Divergence from SAS: PROC RANK groups=10 has its own internal tie-handling
    when building equal-frequency bins; here the 9 interior cutpoints are
    dev's 10th/20th/.../90th percentiles (linear interpolation), which is the
    direct numeric equivalent for columns without heavy value repetition.
    """
    dev_valid = dev.dropna()
    mon_valid = mon.dropna()

    cutpoints = dev_valid.quantile(np.arange(0.1, 1.0, 0.1)).to_numpy()  # 9 interior cuts

    def bucket_of(values: np.ndarray) -> np.ndarray:
        return np.searchsorted(cutpoints, values, side="left")  # 0..9, matches the <=cut1..else-9 ladder

    dev_buckets = bucket_of(dev_valid.to_numpy())
    mon_buckets = bucket_of(mon_valid.to_numpy())

    dev_pct = pd.Series(dev_buckets).value_counts(normalize=True)
    mon_pct = pd.Series(mon_buckets).value_counts(normalize=True)

    psi_val = 0.0
    for b in range(10):
        dp = dev_pct.get(b, 0.000001) or 0.000001
        mp = mon_pct.get(b, 0.000001) or 0.000001
        psi_val += (mp - dp) * math.log(mp / dp)

    if psi_val < psi_stable:
        label = "stable"
    elif psi_val < psi_shift:
        label = "monitor"
    else:
        label = "shift"

    return round(psi_val, 4), label


def drift_tech3_csi(dev: pd.DataFrame, mon: pd.DataFrame, feature_cols: Sequence[str],
                     psi_stable: float = 0.10, psi_shift: float = 0.25) -> pd.DataFrame:
    """<-> %drift_tech3_csi. PSI (CSI) applied to each raw feature."""
    rows = []
    for v in feature_cols:
        csi, label = _psi_one_feature(dev[v], mon[v], psi_stable, psi_shift)
        rows.append({"feature": v, "csi": csi, "label": label})
    return pd.DataFrame(rows)


def drift_tech4_score_psi(dev: pd.DataFrame, mon: pd.DataFrame, score_col: str,
                           psi_stable: float = 0.10, psi_shift: float = 0.25) -> dict:
    """<-> %drift_tech4_score_psi. Same PSI formula on the model score column
    (the System Stability Index)."""
    psi, label = _psi_one_feature(dev[score_col], mon[score_col], psi_stable, psi_shift)
    return {"score_column": score_col, "psi": psi, "label": label}


def drift_tech5_target(dev: pd.DataFrame, mon: pd.DataFrame, target_col: str,
                        drift_notable: float = 3, drift_critical: float = 8) -> dict:
    """<-> %drift_tech5_target. Event-rate / bad-rate shift, dev vs mon.
    Assumes target_col is a 0/1 numeric flag."""
    dev_rate = float(dev[target_col].mean()) * 100
    mon_rate = float(mon[target_col].mean()) * 100
    delta_pp = mon_rate - dev_rate

    if abs(delta_pp) < drift_notable:
        label = "stable"
    elif abs(delta_pp) < drift_critical:
        label = "notable"
    else:
        label = "critical"

    return {
        "target": target_col, "dev_event_rate_pct": round(dev_rate, 2),
        "mon_event_rate_pct": round(mon_rate, 2), "delta_pp": round(delta_pp, 2), "label": label,
    }


def drift_tech6_distribution_stats(dev: pd.DataFrame, mon: pd.DataFrame) -> pd.DataFrame:
    """<-> %drift_tech6_distribution_stats. Cardinality/std/CV/kurtosis drift,
    quantile shift - reuses dq_tech1_profile on dev/mon like the SAS macro
    reuses %dq_tech1_profile, rather than recomputing stats from scratch."""
    dev_prof = dq_tech1_profile(dev).assign(_key=lambda d: d["name"].str.upper())
    mon_prof = dq_tech1_profile(mon).assign(_key=lambda d: d["name"].str.upper())

    joined = dev_prof.merge(mon_prof, on="_key", how="inner", suffixes=("_dev", "_mon"))
    joined = joined[joined["type_dev"] == 1].copy()  # numeric columns only

    rows = []
    for _, r in joined.iterrows():
        row = {"name": r["name_dev"]}

        # Raw side-by-side values, ahead of the derived change/delta metrics
        # below -- lets a reader see what the numbers actually were, not
        # just how much they moved.
        row["dev_mean"] = round(r["mean_dev"], 4) if pd.notna(r["mean_dev"]) else None
        row["mon_mean"] = round(r["mean_mon"], 4) if pd.notna(r["mean_mon"]) else None
        row["dev_std"] = round(r["std_dev"], 4) if pd.notna(r["std_dev"]) else None
        row["mon_std"] = round(r["std_mon"], 4) if pd.notna(r["std_mon"]) else None
        row["dev_min"] = r["min_dev"] if pd.notna(r["min_dev"]) else None
        row["mon_min"] = r["min_mon"] if pd.notna(r["min_mon"]) else None
        row["dev_max"] = r["max_dev"] if pd.notna(r["max_dev"]) else None
        row["mon_max"] = r["max_mon"] if pd.notna(r["max_mon"]) else None
        row["dev_skewness"] = round(r["skewness_dev"], 4) if pd.notna(r["skewness_dev"]) else None
        row["mon_skewness"] = round(r["skewness_mon"], 4) if pd.notna(r["skewness_mon"]) else None

        if r["cardinality_count_dev"] > 0:
            row["cardinality_pct_change"] = round(
                (r["cardinality_count_mon"] - r["cardinality_count_dev"]) / r["cardinality_count_dev"], 3)

        if r["std_dev"] > 0:
            row["std_drift_pct"] = round((r["std_mon"] - r["std_dev"]) / r["std_dev"], 3)

        dev_cv = round(r["std_dev"] / r["mean_dev"], 4) if r["mean_dev"] != 0 else None
        mon_cv = round(r["std_mon"] / r["mean_mon"], 4) if r["mean_mon"] != 0 else None
        row["dev_cv"], row["mon_cv"] = dev_cv, mon_cv
        if dev_cv not in (None, 0):
            row["cv_drift_pct"] = round((mon_cv - dev_cv) / dev_cv, 3)

        row["kurtosis_delta"] = round(r["kurtosis_mon"] - r["kurtosis_dev"], 4)

        dev_iqr = r["q75_dev"] - r["q25_dev"]
        if dev_iqr > 0:
            row["median_shift_iqr"] = round((r["q50_mon"] - r["q50_dev"]) / dev_iqr, 4)

        rows.append(row)

    return pd.DataFrame(rows)


def drift_tech7_entropy(dev: pd.DataFrame, mon: pd.DataFrame, categorical_cols: Sequence[str]) -> pd.DataFrame:
    """<-> %drift_tech7_entropy. Shannon entropy (base 2) of the category
    frequency distribution, dev vs mon. Missing values excluded, matching
    PROC FREQ's default (no /missing option in the SAS macro)."""
    rows = []
    for v in categorical_cols:
        dev_p = dev[v].dropna().value_counts(normalize=True)
        mon_p = mon[v].dropna().value_counts(normalize=True)

        dev_h = float(-(dev_p * np.log2(dev_p)).sum())
        mon_h = float(-(mon_p * np.log2(mon_p)).sum())

        rows.append({
            "feature": v, "dev_entropy": round(dev_h, 4), "mon_entropy": round(mon_h, 4),
            "entropy_delta": round(mon_h - dev_h, 4),
        })

    return pd.DataFrame(rows)


def _ks_one_feature(dev: pd.Series, mon: pd.Series, ks_stable: float = 0.10, ks_shift: float = 0.20):
    """<-> %_ks_one_feature. Approximate KS: max CDF gap at dev's 5 checkpoints
    (min/Q1/median/Q3/max), interpolating mon's CDF from mon's own 5 points."""
    dpts = dev.dropna().quantile([0, 0.25, 0.5, 0.75, 1.0]).to_numpy()
    mpts = mon.dropna().quantile([0, 0.25, 0.5, 0.75, 1.0]).to_numpy()
    cdf = np.array([0.0, 0.25, 0.50, 0.75, 1.0])

    # np.interp clamps to the edge value outside [mpts[0], mpts[-1]], same as
    # the explicit x<=mpts{1}/x>=mpts{5} branches in the SAS macro.
    mon_cdf_at_dpts = np.interp(dpts, mpts, cdf)
    ks_stat = float(np.max(np.abs(mon_cdf_at_dpts - cdf)))

    if ks_stat < ks_stable:
        label = "stable"
    elif ks_stat < ks_shift:
        label = "monitor"
    else:
        label = "shift"

    return round(ks_stat, 4), label


def drift_tech8_ks(dev: pd.DataFrame, mon: pd.DataFrame, feature_cols: Sequence[str],
                    ks_stable: float = 0.10, ks_shift: float = 0.20) -> pd.DataFrame:
    """<-> %drift_tech8_ks."""
    rows = []
    for v in feature_cols:
        ks_stat, label = _ks_one_feature(dev[v], mon[v], ks_stable, ks_shift)
        rows.append({"feature": v, "ks_statistic": ks_stat, "label": label})
    return pd.DataFrame(rows)


def _categorical_psi_one_feature(dev: pd.Series, mon: pd.Series,
                                  psi_stable: float = 0.10, psi_shift: float = 0.25):
    """<-> %_categorical_psi_one_feature. Same PSI formula, buckets = actual
    category values (union of both periods), like PROC FREQ + full join."""
    dev_counts = dev.value_counts(dropna=True)
    mon_counts = mon.value_counts(dropna=True)
    dev_n, mon_n = dev_counts.sum(), mon_counts.sum()

    categories = sorted(set(dev_counts.index) | set(mon_counts.index), key=str)

    psi_val = 0.0
    for cat in categories:
        dev_pct = max(dev_counts.get(cat, 0) / dev_n, 0.000001) if dev_n else 0.000001
        mon_pct = max(mon_counts.get(cat, 0) / mon_n, 0.000001) if mon_n else 0.000001
        psi_val += (mon_pct - dev_pct) * math.log(mon_pct / dev_pct)

    if psi_val < psi_stable:
        label = "stable"
    elif psi_val < psi_shift:
        label = "monitor"
    else:
        label = "shift"

    return round(psi_val, 4), label


def drift_tech9_categorical_psi(dev: pd.DataFrame, mon: pd.DataFrame, categorical_cols: Sequence[str],
                                 psi_stable: float = 0.10, psi_shift: float = 0.25) -> pd.DataFrame:
    """<-> %drift_tech9_categorical_psi."""
    rows = []
    for v in categorical_cols:
        psi, label = _categorical_psi_one_feature(dev[v], mon[v], psi_stable, psi_shift)
        rows.append({"feature": v, "psi": psi, "label": label})
    return pd.DataFrame(rows)


def drift_calc_wrapper(dev: pd.DataFrame, mon: pd.DataFrame, target_col: Optional[str] = None,
                        score_col: Optional[str] = None, feature_cols: ColumnList = None,
                        categorical_cols: ColumnList = None,
                        psi_stable: float = 0.10, psi_shift: float = 0.25,
                        ks_stable: float = 0.10, ks_shift: float = 0.20) -> dict:
    """<-> %drift_calc_wrapper. Orchestrates the 9 drift techniques, dev vs mon."""
    # feature_cols/categorical_cols are real dataframe column names (case-sensitive),
    # unlike id_cols/private_cols which are matched case-insensitively in dq_tech3_governance.
    # A space-separated string is split as a convenience; a list is used as-is.
    feature_cols = feature_cols.split() if isinstance(feature_cols, str) else (feature_cols or [])
    categorical_cols = categorical_cols.split() if isinstance(categorical_cols, str) else (categorical_cols or [])

    out = {
        "schema": drift_tech1_schema(dev, mon),
        "completeness": drift_tech2_completeness(dev, mon),
    }

    if feature_cols:
        out["csi"] = drift_tech3_csi(dev, mon, feature_cols, psi_stable, psi_shift)
        out["distribution"] = drift_tech6_distribution_stats(dev, mon)
        out["ks"] = drift_tech8_ks(dev, mon, feature_cols, ks_stable, ks_shift)

    if score_col:
        out["score_psi"] = drift_tech4_score_psi(dev, mon, score_col, psi_stable, psi_shift)

    if target_col:
        out["target"] = drift_tech5_target(dev, mon, target_col)

    if categorical_cols:
        out["entropy"] = drift_tech7_entropy(dev, mon, categorical_cols)
        out["categorical_psi"] = drift_tech9_categorical_psi(dev, mon, categorical_cols, psi_stable, psi_shift)

    return out


# ============================================================================
# 00_main_wrapper.sas -> top-level entry point
# ============================================================================

def main_wrapper(dev_dta: pd.DataFrame, mon_dta: Optional[pd.DataFrame] = None,
                  is_dq_req: bool = False, is_drift_req: bool = False,
                  order: str = "DQ_FIRST",
                  target_col: Optional[str] = None, score_col: Optional[str] = None,
                  id_cols: ColumnList = None, private_cols: ColumnList = None,
                  feature_cols: ColumnList = None, categorical_cols: ColumnList = None,
                  missing_thresh: float = 50, id_uniqueness_thresh: float = 99.9,
                  leakage_card_min: float = 50,
                  psi_stable: float = 0.10, psi_shift: float = 0.25,
                  ks_stable: float = 0.10, ks_shift: float = 0.20,
                  drift_notable: float = 3, drift_critical: float = 8) -> dict:
    """<-> %main_wrapper. order= DQ_FIRST | DRIFT_FIRST, matching the SAS
    entry point's flag-driven orchestration."""
    results = {}

    def _run_dq():
        if is_dq_req:
            results["dq_dev"] = dq_calc_wrapper(
                dev_dta, target_col=target_col, id_cols=id_cols, private_cols=private_cols,
                missing_thresh=missing_thresh, id_uniqueness_thresh=id_uniqueness_thresh,
                leakage_card_min=leakage_card_min)
            if mon_dta is not None:
                results["dq_mon"] = dq_calc_wrapper(
                    mon_dta, target_col=target_col, id_cols=id_cols, private_cols=private_cols,
                    missing_thresh=missing_thresh, id_uniqueness_thresh=id_uniqueness_thresh,
                    leakage_card_min=leakage_card_min)

    def _run_drift():
        if is_drift_req and mon_dta is not None:
            results["drift"] = drift_calc_wrapper(
                dev_dta, mon_dta, target_col=target_col, score_col=score_col,
                feature_cols=feature_cols, categorical_cols=categorical_cols,
                psi_stable=psi_stable, psi_shift=psi_shift, ks_stable=ks_stable, ks_shift=ks_shift)

    if order.upper() == "DRIFT_FIRST":
        _run_drift()
        _run_dq()
    else:
        _run_dq()
        _run_drift()

    return results


if __name__ == "__main__":
    # Self-check only - not part of the app. Run directly:
    #   python sas_macros/dq_drift_python_translation.py
    import os

    base = os.path.join(os.path.dirname(__file__), "..", "data")
    dev_path = os.path.join(base, "development_data_5000_shap.csv")
    mon_path = os.path.join(base, "monitoring_data_5000_shap.csv")

    if not (os.path.exists(dev_path) and os.path.exists(mon_path)):
        print("Sample data not found at", dev_path, "/", mon_path, "- skipping self-check.")
    else:
        dev_df = pd.read_csv(dev_path)
        mon_df = pd.read_csv(mon_path)

        results = main_wrapper(
            dev_df, mon_df, is_dq_req=True, is_drift_req=True,
            target_col="default_flag", score_col="pd_score", id_cols="customer_id",
            feature_cols=["age", "bureau_score", "dti", "utilization"],
            categorical_cols=["region", "employment_type"],
        )

        print("\n=== DQ (dev) health ===")
        print(results["dq_dev"]["health"])
        print("Readiness score:", results["dq_dev"]["readiness_score"])

        print("\n=== Drift: CSI ===")
        print(results["drift"]["csi"])

        print("\n=== Drift: score PSI ===")
        print(results["drift"]["score_psi"])

        print("\n=== Drift: target ===")
        print(results["drift"]["target"])

        print("\n=== Drift: categorical PSI ===")
        print(results["drift"]["categorical_psi"])

        print("\n=== Drift: KS ===")
        print(results["drift"]["ks"])
