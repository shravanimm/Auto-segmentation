"""
utils/outliers.py
=================
Outlier detection and treatment shared by all segmentation techniques.

Design
------
* **Fit on Development only.** Bounds / models are learned from the
  development population and applied unchanged to Monitoring, so outlier
  handling never leaks monitoring data and stays comparable across periods
  (same principle as the K-Means encoder).
* **Univariate (per feature): double-MAD modified z-score.** Median +/- k * 1.4826 * MAD,
  with a *separate* MAD for each side of the median, so skewed features
  (balances, amounts, counts) are not over-flagged on the long tail the way
  mean/std or symmetric MAD rules are. Falls back to Tukey IQR fences when a
  side's MAD is 0 (zero-inflated features). Discrete / constant features are skipped.
* **Multivariate: Isolation Forest.** Row-level anomaly flag that catches
  unusual feature *combinations* that look normal one column at a time.
  Threshold is the development score quantile, so the dev flag rate equals the
  configured contamination and the monitoring flag rate is a drift signal.
* **Treatment: winsorize (clip) to the fences.** Keeps every row (no change to
  segment sizes or rule evaluation) while stopping extremes from dominating
  scalers, clustering distances and tree splits.
"""

from __future__ import annotations

import logging
from typing import Optional

import numpy as np
import pandas as pd

from models.config import OutlierConfig

logger = logging.getLogger(__name__)

_MAD_SCALE = 1.4826  # makes MAD consistent with std under normality


# ---------------------------------------------------------------------------
# Univariate bounds
# ---------------------------------------------------------------------------

def _column_bounds(values: np.ndarray, cfg: OutlierConfig) -> Optional[tuple[float, float, str]]:
    """Return ``(lower, upper, method)`` for one column or ``None`` to skip."""
    values = values[np.isfinite(values)]
    if len(values) < cfg.min_rows or len(np.unique(values)) < cfg.min_unique:
        return None

    median = float(np.median(values))
    q25, q75 = np.percentile(values, [25, 75])
    iqr = float(q75 - q25)

    sides = []
    method = "double_mad"
    for side_vals, sign in ((values[values <= median], -1), (values[values >= median], 1)):
        mad = float(np.median(np.abs(side_vals - median)))
        if mad > 0:
            sides.append(median + sign * cfg.mad_threshold * _MAD_SCALE * mad)
        elif iqr > 0:
            # Zero-inflated side: fall back to far-out Tukey fence.
            method = "double_mad+iqr_fallback"
            base = q25 if sign < 0 else q75
            sides.append(base + sign * cfg.iqr_multiplier * iqr)
        else:
            sides.append(-np.inf if sign < 0 else np.inf)

    lower, upper = sides
    if not np.isfinite(lower) and not np.isfinite(upper):
        return None

    # Never let a fence cut inside the observed central 99% -- guards against
    # over-flagging on heavy but legitimate distributions.
    p_lo, p_hi = np.percentile(values, [cfg.min_clip_pct * 100, (1 - cfg.min_clip_pct) * 100])
    lower, upper = min(lower, float(p_lo)), max(upper, float(p_hi))

    # Domain-aware clamp: MAD fences assume bell-shaped tails and can land outside
    # any possible value (negative amounts, utilization > 100%). Keep fences inside
    # the natural limits the development data itself implies.
    vmin, vmax = float(values.min()), float(values.max())
    if vmin >= 0:
        lower = max(lower, 0.0)
        if vmax <= 1:
            upper = min(upper, 1.0)
        elif vmax <= 100:
            upper = min(upper, 100.0)
    return lower, upper, method


def fit_outlier_bounds(dev_df: pd.DataFrame, numeric_cols: list[str], cfg: OutlierConfig) -> dict:
    """Learn per-column fences (and optionally an Isolation Forest) from dev data."""
    bounds: dict[str, tuple[float, float, str]] = {}
    ranges: dict[str, tuple[float, float]] = {}
    for c in numeric_cols:
        if c not in dev_df.columns:
            continue
        vals = pd.to_numeric(dev_df[c], errors="coerce").to_numpy(dtype=float)
        b = _column_bounds(vals, cfg)
        vr = cfg.valid_ranges.get(c)
        if vr:
            v_lo = -np.inf if vr[0] is None else float(vr[0])
            v_hi = np.inf if vr[1] is None else float(vr[1])
            if b is None:
                # Too discrete/small for statistical fences, but the business rule still applies.
                b = (v_lo, v_hi, "valid_range") if (np.isfinite(v_lo) or np.isfinite(v_hi)) else None
            else:
                b = (max(b[0], v_lo), min(b[1], v_hi), b[2] + "+valid_range")
        if b is not None:
            bounds[c] = b
            fin = vals[np.isfinite(vals)]
            ranges[c] = (float(fin.min()), float(fin.max()))

    model = None
    mv_cols = list(bounds)  # continuous features only; flags/codes add noise
    if cfg.multivariate and len(mv_cols) >= 2 and len(dev_df) >= cfg.min_rows:
        from sklearn.ensemble import IsolationForest

        medians = dev_df[mv_cols].median()
        X = _clip_frame(dev_df[mv_cols].fillna(medians), bounds)
        iso = IsolationForest(
            n_estimators=100,
            max_samples=min(256, len(X)),
            random_state=cfg.random_state,
            n_jobs=-1,
        ).fit(X)
        threshold = float(np.quantile(iso.score_samples(X), cfg.contamination))
        model = {"iso": iso, "threshold": threshold, "medians": medians, "cols": mv_cols}

    return {"bounds": bounds, "ranges": ranges, "valid_ranges": dict(cfg.valid_ranges), "multivariate": model}


# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

def _clip_frame(df: pd.DataFrame, bounds: dict) -> pd.DataFrame:
    out = df.copy()
    for c, (lo, hi, _) in bounds.items():
        if c in out.columns:
            out[c] = out[c].clip(lower=lo, upper=hi)
    return out


def count_range_violations(series: pd.Series, valid_range) -> int:
    """Values outside a configured (min, max) business range; None = open side."""
    if not valid_range:
        return 0
    v = pd.to_numeric(series, errors="coerce")
    lo, hi = valid_range
    bad = pd.Series(False, index=v.index)
    if lo is not None:
        bad |= v < lo
    if hi is not None:
        bad |= v > hi
    return int(bad.sum())


def clip_to_bounds(df: pd.DataFrame, fitted: Optional[dict]) -> pd.DataFrame:
    """Winsorize numeric columns to the dev-fitted fences (copy; NaNs untouched)."""
    if not fitted or not fitted["bounds"]:
        return df
    return _clip_frame(df, fitted["bounds"])


def apply_treatment(df: pd.DataFrame, fitted: Optional[dict], cfg: Optional[OutlierConfig]) -> pd.DataFrame:
    """Apply the configured treatment ("none" returns *df* unchanged)."""
    if cfg is None or cfg.treatment == "none":
        return df
    return clip_to_bounds(df, fitted)


def flag_outliers(df: pd.DataFrame, fitted: dict) -> pd.DataFrame:
    """Row-level flags: ``outlier_univariate_n`` (count of features beyond fences),
    ``outlier_univariate`` and, if fitted, ``outlier_multivariate``."""
    flags = pd.DataFrame(index=df.index)
    n_out = np.zeros(len(df), dtype=int)
    for c, (lo, hi, _) in fitted["bounds"].items():
        if c in df.columns:
            v = pd.to_numeric(df[c], errors="coerce")
            n_out += ((v < lo) | (v > hi)).to_numpy()
    flags["outlier_univariate_n"] = n_out
    flags["outlier_univariate"] = n_out > 0

    m = fitted.get("multivariate")
    if m is not None:
        X = _clip_frame(df.reindex(columns=m["cols"]).fillna(m["medians"]), fitted["bounds"])
        flags["outlier_multivariate"] = m["iso"].score_samples(X) < m["threshold"]
    return flags


def summarize_outliers(dev_df: pd.DataFrame, mon_df: pd.DataFrame, fitted: dict) -> dict:
    """Per-feature and row-level outlier rates for dev vs monitoring.

    A monitoring rate far above the dev rate is itself a drift signal."""
    rows = []
    for c, (lo, hi, method) in fitted["bounds"].items():
        d = pd.to_numeric(dev_df[c], errors="coerce")
        m = pd.to_numeric(mon_df[c], errors="coerce")
        rows.append({
            "feature": c, "lower": lo, "upper": hi, "method": method,
            "dev_outlier_pct": float(((d < lo) | (d > hi)).mean()),
            "mon_outlier_pct": float(((m < lo) | (m > hi)).mean()),
        })
    per_feature = pd.DataFrame(rows)
    dev_flags, mon_flags = flag_outliers(dev_df, fitted), flag_outliers(mon_df, fitted)
    row_level = {
        k: {"dev_pct": float(dev_flags[k].mean()), "mon_pct": float(mon_flags[k].mean())}
        for k in ("outlier_univariate", "outlier_multivariate") if k in dev_flags
    }
    return {"per_feature": per_feature, "row_level": row_level}


def log_outlier_summary(tag: str, dev_df: pd.DataFrame, mon_df: pd.DataFrame, fitted: dict) -> None:
    try:
        s = summarize_outliers(dev_df, mon_df, fitted)
        logger.info("%s outliers: %d features bounded; row-level %s", tag, len(fitted["bounds"]), s["row_level"])
    except Exception as exc:  # diagnostics must never break a run
        logger.warning("%s outlier summary failed: %s", tag, exc)
