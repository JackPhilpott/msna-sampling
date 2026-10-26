"""Step 3: resampling under access constraints.

In each round, every partner returns an accessibility report on its active
clusters (synthetic here: a cluster is reported inaccessible at random, more
often near an inaccessible zone). Each inaccessible cluster is replaced by a
new PPS draw from what is left of its stratum's eligible pool: accessible PSUs
not already selected and not reported inaccessible. When the pool runs dry,
the gap is logged as a shortfall.

Inputs: data/synthetic/{frame_psus,lgas,clusters}.csv
Outputs: data/synthetic/accessibility_reports/round<r>_<partner>.csv
         data/synthetic/{clusters_after_resampling,resample_log}.csv
"""
import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))
from sampling_tools import draw_replacements, load_config, output_dir  # noqa: E402

CLUSTER_COLS = ["cluster_id", "psu_id", "stratum_id", "pop_type", "adm1_name", "adm1_pcode",
                "adm2_name", "adm2_pcode", "partner", "draw", "lon", "lat"]


def main() -> int:
    cfg = load_config()
    rs = cfg["resampling"]
    out = output_dir(cfg)
    rng = np.random.default_rng(cfg["seed"])

    lgas = pd.read_csv(out / "lgas.csv")[["adm1_name", "adm1_pcode", "adm2_name", "adm2_pcode",
                                          "surveyed", "partner"]]
    frame = pd.read_csv(out / "frame_psus.csv").merge(lgas, on="adm2_pcode", how="left")
    frame["stratum_id"] = frame["pop_type"] + "_" + frame["adm2_pcode"]
    eligible = frame[frame["surveyed"] & frame["accessible"] & (frame["size_hh"] > 0)]
    eligible = eligible.sort_values(["stratum_id", "frame_order"])
    near_zone = frame.set_index("psu_id")["near_zone"]

    clusters = pd.read_csv(out / "clusters.csv")
    clusters = clusters.assign(status="active", round_added=0, round_removed=pd.NA, replaces="")

    reports_dir = out / "accessibility_reports"
    reports_dir.mkdir(exist_ok=True)
    for old in reports_dir.glob("*.csv"):
        old.unlink()

    blocked: set[str] = set()
    log = []
    for rnd, p in enumerate(rs["p_inaccessible"], start=1):
        active = clusters[clusters["status"] == "active"]
        # access is decided per PSU: when a place cannot be reached, none of its clusters can
        psus = np.sort(active["psu_id"].unique())
        near = pd.Series(psus).map(near_zone).fillna(False).to_numpy(dtype=bool)
        prob = np.clip(np.where(near, p * rs["p_near_zone_multiplier"], p), 0, 0.9)
        unreachable = set(psus[rng.random(len(psus)) < prob])
        report = active[["cluster_id", "psu_id", "stratum_id", "pop_type", "adm1_name", "adm2_name",
                         "partner"]].assign(
            round=rnd,
            reported_status=np.where(active["psu_id"].isin(unreachable), "inaccessible", "accessible"))
        for partner, rep in report.groupby("partner"):
            rep.to_csv(reports_dir / f"round{rnd}_{partner.lower().replace(' ', '_')}.csv", index=False, lineterminator="\n")

        lost_all = report[report["reported_status"] == "inaccessible"]
        is_lost = clusters["cluster_id"].isin(lost_all["cluster_id"])
        clusters.loc[is_lost, "status"] = "inaccessible"
        clusters.loc[is_lost, "round_removed"] = rnd
        blocked |= set(lost_all["psu_id"])
        used = set(clusters["psu_id"])

        new_rows = []
        for stratum, lost in lost_all.groupby("stratum_id", sort=True):
            pool = eligible[(eligible["stratum_id"] == stratum) & ~eligible["psu_id"].isin(used | blocked)]
            picks = draw_replacements(pool, len(lost), rng)
            by_psu = pool.set_index("psu_id")
            for k, (psu, replaced) in enumerate(zip(picks, lost["cluster_id"]), start=1):
                row = by_psu.loc[psu]
                new_rows.append({
                    "cluster_id": f"{stratum}_R{rnd}_{k:02d}", "psu_id": psu, "stratum_id": stratum,
                    "pop_type": row["pop_type"], "adm1_name": row["adm1_name"], "adm1_pcode": row["adm1_pcode"],
                    "adm2_name": row["adm2_name"], "adm2_pcode": row["adm2_pcode"], "partner": row["partner"],
                    "draw": f"replacement_round{rnd}", "lon": row["lon"], "lat": row["lat"],
                    "status": "active", "round_added": rnd, "round_removed": pd.NA, "replaces": replaced,
                })
            first = lost.iloc[0]
            log.append({
                "round": rnd, "stratum_id": stratum, "pop_type": first["pop_type"],
                "adm1_name": first["adm1_name"], "adm2_name": first["adm2_name"], "partner": first["partner"],
                "reported_inaccessible": len(lost), "replaced": len(picks),
                "shortfall": len(lost) - len(picks), "pool_psus_left": len(pool) - len(set(picks)),
            })
        if new_rows:
            clusters = pd.concat([clusters, pd.DataFrame(new_rows)], ignore_index=True)
        print(f"Round {rnd}: {len(lost_all)} clusters reported inaccessible, "
              f"{len(new_rows)} replaced, {len(lost_all) - len(new_rows)} shortfall")

    clusters = clusters[CLUSTER_COLS + ["status", "round_added", "round_removed", "replaces"]]
    clusters.to_csv(out / "clusters_after_resampling.csv", index=False, lineterminator="\n")
    log = pd.DataFrame(log)
    log.to_csv(out / "resample_log.csv", index=False, lineterminator="\n")

    active = clusters[clusters["status"] == "active"]
    hh = len(active) * cfg["sample_size"]["cluster_size"]
    print(f"After resampling: {len(active):,} active clusters ({(active['round_added'] > 0).sum():,} replacements), "
          f"{hh:,} households to interview, total shortfall {int(log['shortfall'].sum()) if len(log) else 0} clusters")
    return 0


if __name__ == "__main__":
    sys.exit(main())
