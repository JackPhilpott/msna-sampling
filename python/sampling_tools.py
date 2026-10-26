"""Shared tools for the Python steps of the sampling pipeline."""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd
import yaml

ROOT = Path(__file__).resolve().parents[1]
SYNTHETIC_LABEL = "Synthetic data – not real findings"


def load_config(path: Path = ROOT / "config.yml") -> dict:
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f)


def output_dir(cfg: dict) -> Path:
    return ROOT / cfg["outputs"]["dir"]


def pps_systematic(size: np.ndarray, n: int, rng: np.random.Generator) -> np.ndarray:
    """Systematic probability-proportional-to-size selection with a random start.

    Same rule as pps_systematic() in R/functions.R: units are taken in the order
    given, and a unit larger than the sampling interval can be hit more than once.
    Returns the 0-based index of the unit hit by each of the n selection points.
    """
    size = np.asarray(size, dtype=float)
    if n <= 0:
        return np.array([], dtype=int)
    if (size < 0).any():
        raise ValueError("sizes must be non-negative")
    interval = size.sum() / n
    start = rng.uniform(0, interval)
    points = start + np.arange(n) * interval
    return np.searchsorted(np.cumsum(size), points, side="left")


def draw_replacements(pool: pd.DataFrame, n: int, rng: np.random.Generator) -> list[str]:
    """Draw n replacement PSUs from a stratum's remaining eligible pool.

    `pool` holds the PSUs still eligible (not inaccessible, not already
    selected), in frame order, with their size in households. Returns the
    psu_id of each replacement; fewer than n means a shortfall.
    """
    pool = pool[pool["size_hh"] > 0]
    if n <= 0 or pool.empty:
        return []
    idx = pps_systematic(pool["size_hh"].to_numpy(), n, rng)
    return pool["psu_id"].to_numpy()[idx].tolist()
