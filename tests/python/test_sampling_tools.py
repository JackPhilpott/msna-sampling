import sys
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "python"))
from sampling_tools import draw_replacements, pps_systematic  # noqa: E402


def test_same_seed_same_selection():
    size = np.array([5, 40, 12, 3, 80, 25, 9])
    a = pps_systematic(size, 4, np.random.default_rng(1))
    b = pps_systematic(size, 4, np.random.default_rng(1))
    assert (a == b).all()


def test_selection_probability_is_proportional_to_size():
    size = np.array([10, 20, 30, 40, 100])
    n, reps = 3, 20000
    rng = np.random.default_rng(42)
    counts = np.zeros(len(size))
    for _ in range(reps):
        counts += np.bincount(pps_systematic(size, n, rng), minlength=len(size))
    np.testing.assert_allclose(counts / reps, n * size / size.sum(), atol=0.02)


def test_zero_size_units_are_never_selected():
    size = np.array([0, 10, 0, 10, 0])
    rng = np.random.default_rng(3)
    hits = np.concatenate([pps_systematic(size, 2, rng) for _ in range(500)])
    assert set(hits) <= {1, 3}


def test_replacements_come_from_the_pool_only():
    pool = pd.DataFrame({"psu_id": ["h1", "h2", "h3"], "size_hh": [50, 0, 120]})
    picks = draw_replacements(pool, 5, np.random.default_rng(0))
    assert len(picks) == 5
    assert set(picks) <= {"h1", "h3"}


def test_empty_pool_gives_a_full_shortfall():
    pool = pd.DataFrame({"psu_id": ["h1"], "size_hh": [0]})
    assert draw_replacements(pool, 3, np.random.default_rng(0)) == []


def test_negative_sizes_are_rejected():
    with pytest.raises(ValueError):
        pps_systematic(np.array([1, -1]), 1, np.random.default_rng(0))
