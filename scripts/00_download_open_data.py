"""Download the two open datasets the pipeline needs into data/raw/.

- HDX COD-AB administrative boundaries for Nigeria (CC BY-IGO)
- WorldPop constrained population for Nigeria, 2026, 1 km (CC BY 4.0)

Complete files are skipped. Interrupted downloads resume where they stopped,
which matters on slow or unreliable connections.
"""
import sys
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
TIMEOUT_S = 60
ATTEMPTS = 8


def remote_size(url: str) -> int:
    with urllib.request.urlopen(urllib.request.Request(url, method="HEAD"), timeout=TIMEOUT_S) as r:
        return int(r.headers.get("Content-Length", 0))


def download(url: str, dest: Path) -> None:
    expected = remote_size(url)
    if dest.exists() and dest.stat().st_size == expected:
        print(f"  already downloaded: {dest.name}", flush=True)
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_suffix(dest.suffix + ".part")
    print(f"  downloading {dest.name} ({expected / 1e6:.1f} MB)", flush=True)
    for attempt in range(1, ATTEMPTS + 1):
        have = part.stat().st_size if part.exists() else 0
        req = urllib.request.Request(url, headers={"Range": f"bytes={have}-"} if have else {})
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT_S) as r:
                mode = "ab" if have and r.status == 206 else "wb"
                with open(part, mode) as f:
                    while chunk := r.read(1 << 16):
                        f.write(chunk)
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            print(f"  attempt {attempt} stopped at {part.stat().st_size / 1e6:.1f} MB ({e}); resuming",
                  flush=True)
            time.sleep(min(30, 2 ** attempt))
            continue
        if part.stat().st_size == expected:
            part.replace(dest)
            print(f"  done: {dest.name}", flush=True)
            return
    raise RuntimeError(f"could not download {dest.name} after {ATTEMPTS} attempts")


def main() -> int:
    cfg = yaml.safe_load(open(ROOT / "config.yml", encoding="utf-8"))["open_data"]

    b = cfg["boundaries"]
    zip_path = ROOT / b["zip"]
    download(b["url"], zip_path)
    out_dir = ROOT / b["dir"]
    if not any(out_dir.glob("**/*.shp")):
        with zipfile.ZipFile(zip_path) as z:
            z.extractall(out_dir)
    print(f"  boundaries: {', '.join(sorted(p.name for p in out_dir.glob('**/*.shp')))}", flush=True)

    p = cfg["population"]
    download(p["url"], ROOT / p["file"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
