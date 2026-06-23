# Valhalla USA Routing Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a self-hosted Valhalla routing engine in Docker covering the full continental USA, queryable over `http://localhost:8002` (incl. truck costing), with fully manual download/build/rebuild control.

**Architecture:** A single Docker Compose service using the prebuilt `gis-ops/docker-valhalla` image. Tiles + PBF persist in a bind-mounted `custom_files/` dir. Default startup serves cached tiles with no network/rebuild; two explicit scripts handle the one-time build and the on-demand newest-map rebuild.

**Tech Stack:** Docker, Docker Compose, `ghcr.io/gis-ops/docker-valhalla/valhalla:latest`, Bash, Python 3 (example client, `requests`).

## Global Constraints

- Image: `ghcr.io/gis-ops/docker-valhalla/valhalla:latest`.
- Host API port: `8002` (overridable via `VALHALLA_PORT`).
- PBF source: `https://download.geofabrik.de/north-america/us-latest.osm.pbf` (overridable via `PBF_URL`).
- Default startup MUST NOT download or rebuild: `force_rebuild=False`, `use_tiles_ignore_pbf=True`, `serve_tiles=True`.
- `custom_files/` MUST be git-ignored (large data, never committed).
- Coverage: full USA lower 48 only. No Canada/Mexico, no auth, no traffic. (YAGNI)

---

### Task 1: Compose service + env + gitignore (serve-by-default)

**Files:**
- Create: `docker-compose.yml`
- Create: `.env.example`
- Modify: `.gitignore` (append `custom_files/`)

**Interfaces:**
- Produces: a compose service named `valhalla` reading env vars `VALHALLA_PORT`, `PBF_URL`, `BUILD_ELEVATION`, `BUILD_ADMINS`, `BUILD_TIME_ZONES`, `FORCE_REBUILD`, `USE_TILES_IGNORE_PBF`. The build/rebuild scripts (Task 2) drive it by overriding `FORCE_REBUILD` and `USE_TILES_IGNORE_PBF`.

- [ ] **Step 1: Write `.env.example`**

```bash
# Host port the Valhalla HTTP API is published on.
VALHALLA_PORT=8002

# Source OSM extract. Full continental USA from Geofabrik.
PBF_URL=https://download.geofabrik.de/north-america/us-latest.osm.pbf

# Tile-build features. Elevation is off by default for a faster first build;
# set to True and rebuild to enable grade-aware truck costing.
BUILD_ELEVATION=False
BUILD_ADMINS=True
BUILD_TIME_ZONES=True

# --- Runtime mode (do not edit for normal use) ---
# Default = serve cached tiles only: never download, never rebuild.
# The build.sh / rebuild.sh scripts override these to perform a build.
FORCE_REBUILD=False
USE_TILES_IGNORE_PBF=True
```

- [ ] **Step 2: Write `docker-compose.yml`**

```yaml
services:
  valhalla:
    image: ghcr.io/gis-ops/docker-valhalla/valhalla:latest
    container_name: valhalla-usa
    restart: unless-stopped
    ports:
      - "${VALHALLA_PORT:-8002}:8002"
    volumes:
      # PBF + built tiles persist here across restarts and rebuilds.
      - ./custom_files:/custom_files
    environment:
      # Always serve the HTTP API.
      server_threads: 4
      serve_tiles: "True"
      # Map source — only used when a build is actually triggered.
      tile_urls: "${PBF_URL:-https://download.geofabrik.de/north-america/us-latest.osm.pbf}"
      # Build features.
      build_elevation: "${BUILD_ELEVATION:-False}"
      build_admins: "${BUILD_ADMINS:-True}"
      build_time_zones: "${BUILD_TIME_ZONES:-True}"
      build_tar: "True"
      # Runtime mode. Defaults = serve cached tiles, no download/rebuild.
      # build.sh / rebuild.sh override FORCE_REBUILD / USE_TILES_IGNORE_PBF.
      force_rebuild: "${FORCE_REBUILD:-False}"
      use_tiles_ignore_pbf: "${USE_TILES_IGNORE_PBF:-True}"
```

- [ ] **Step 3: Append to `.gitignore`**

Add these lines at the end of the existing `.gitignore`:

```gitignore

# Valhalla data: downloaded PBF + built tiles (large, regenerate via scripts).
custom_files/
```

- [ ] **Step 4: Verify compose is valid and resolves serve-mode defaults**

Run: `cp .env.example .env && docker compose config`
Expected: prints the resolved config with `force_rebuild: "False"`, `use_tiles_ignore_pbf: "True"`, port mapping `8002:8002`, and volume `./custom_files:/custom_files`. No errors.

(If Docker is unavailable in the environment, instead run `python3 -c "import yaml,sys; yaml.safe_load(open('docker-compose.yml')); print('yaml ok')"` to confirm valid YAML, and note the live check is deferred.)

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml .env.example .gitignore
git commit -m "feat: add Valhalla compose service (serve-by-default)"
```

---

### Task 2: build.sh and rebuild.sh control scripts

**Files:**
- Create: `scripts/build.sh`
- Create: `scripts/rebuild.sh`

**Interfaces:**
- Consumes: the `valhalla` compose service and env vars from Task 1.
- Produces: two executable scripts. `build.sh` performs a one-time download+build then returns the service to serve mode. `rebuild.sh` clears cached artifacts in `custom_files/` and re-runs `build.sh` to fetch the newest map.

- [ ] **Step 1: Write `scripts/build.sh`**

```bash
#!/usr/bin/env bash
# One-time / explicit build: download the USA PBF and build routing tiles,
# then return the service to normal serve mode.
#
# Usage: scripts/build.sh
# WARNING: downloads ~10 GB and builds for several hours; needs ~100+ GB free
# disk and substantial RAM. The service is unavailable during the build.
set -euo pipefail

cd "$(dirname "$0")/.."

echo ">> Stopping any running Valhalla container..."
docker compose down

echo ">> Building tiles (download + tile build). This takes hours..."
# Override serve-mode defaults so the image actually downloads + builds.
FORCE_REBUILD=True USE_TILES_IGNORE_PBF=False docker compose up -d

echo ">> Build started in the background. Follow progress with:"
echo "   docker compose logs -f valhalla"
echo ">> When logs show the tiles are loaded and the server is listening,"
echo "   the API is live on http://localhost:${VALHALLA_PORT:-8002}"
echo ">> Tiles are now cached in ./custom_files; future 'docker compose up'"
echo "   will serve them without rebuilding."
```

- [ ] **Step 2: Write `scripts/rebuild.sh`**

```bash
#!/usr/bin/env bash
# On-demand rebuild to pull the NEWEST Geofabrik USA map.
# Destructively clears the cached PBF + tiles, then rebuilds from scratch.
#
# Usage: scripts/rebuild.sh
set -euo pipefail

cd "$(dirname "$0")/.."

echo "!! This will DELETE cached tiles + PBF in ./custom_files and rebuild"
echo "!! from the newest Geofabrik USA map (several hours, ~100+ GB disk)."
read -r -p "Continue? [y/N] " reply
case "$reply" in
  [yY][eE][sS]|[yY]) ;;
  *) echo "Aborted."; exit 1 ;;
esac

echo ">> Stopping container..."
docker compose down

echo ">> Removing cached map + tiles..."
# Remove generated artifacts but keep the directory + any user config.
rm -rf \
  custom_files/*.pbf \
  custom_files/*.osm.pbf \
  custom_files/valhalla_tiles \
  custom_files/valhalla_tiles.tar \
  custom_files/*.tar \
  custom_files/timezones.sqlite \
  custom_files/admins.sqlite \
  custom_files/elevation_data

echo ">> Rebuilding from newest map..."
exec "$(dirname "$0")/build.sh"
```

- [ ] **Step 3: Make scripts executable**

Run: `chmod +x scripts/build.sh scripts/rebuild.sh`

- [ ] **Step 4: Verify scripts are syntactically valid**

Run: `bash -n scripts/build.sh && bash -n scripts/rebuild.sh && echo "syntax ok"`
Expected: prints `syntax ok` with no errors.

- [ ] **Step 5: Commit**

```bash
git add scripts/build.sh scripts/rebuild.sh
git commit -m "feat: add explicit build and rebuild control scripts"
```

---

### Task 3: Example truck-route Python client

**Files:**
- Create: `examples/route_truck.py`
- Create: `examples/requirements.txt`

**Interfaces:**
- Consumes: the running HTTP API on `http://localhost:${VALHALLA_PORT}`.
- Produces: a runnable reference client other scripts can copy: function `route_truck(start, end, base_url)` returning the parsed JSON response.

- [ ] **Step 1: Write `examples/requirements.txt`**

```
requests>=2.31
```

- [ ] **Step 2: Write `examples/route_truck.py`**

```python
#!/usr/bin/env python3
"""Reference client: request a truck route from the local Valhalla service.

Run the service first (docker compose up), then:
    python examples/route_truck.py
Other scripts can import route_truck() or copy this pattern.
"""
import json
import os
import sys

import requests

BASE_URL = os.environ.get("VALHALLA_URL", "http://localhost:8002")


def route_truck(start, end, base_url=BASE_URL):
    """Return Valhalla's JSON route for a truck between two (lat, lon) points.

    start, end: (lat, lon) tuples.
    """
    payload = {
        "locations": [
            {"lat": start[0], "lon": start[1]},
            {"lat": end[0], "lon": end[1]},
        ],
        "costing": "truck",
        "costing_options": {
            "truck": {
                "height": 4.11,
                "width": 2.6,
                "length": 21.64,
                "weight": 36.3,
                "axle_load": 9.07,
                "hazmat": False,
            }
        },
        "units": "miles",
    }
    resp = requests.post(f"{base_url}/route", json=payload, timeout=30)
    resp.raise_for_status()
    return resp.json()


def main():
    # Chicago, IL -> Indianapolis, IN
    start = (41.8781, -87.6298)
    end = (39.7684, -86.1581)
    result = route_truck(start, end)
    summary = result["trip"]["summary"]
    print(f"Distance: {summary['length']:.1f} mi, "
          f"time: {summary['time'] / 3600:.2f} h")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    try:
        main()
    except requests.RequestException as exc:
        print(f"Request failed: {exc}", file=sys.stderr)
        sys.exit(1)
```

- [ ] **Step 3: Verify the script parses and imports cleanly**

Run: `python3 -m py_compile examples/route_truck.py && echo "compile ok"`
Expected: prints `compile ok`.

(A live run requires built tiles; defer the real request to Task 4's smoke test.)

- [ ] **Step 4: Commit**

```bash
git add examples/route_truck.py examples/requirements.txt
git commit -m "feat: add truck-route example client"
```

---

### Task 4: README with operations + query examples

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: everything from Tasks 1-3.
- Produces: user-facing docs for the serve/build/rebuild workflow and query examples.

- [ ] **Step 1: Replace `README.md` with the following**

````markdown
# OSM Valhalla — USA Routing Service

Self-hosted [Valhalla](https://github.com/valhalla/valhalla) routing engine
covering the continental USA, served at `http://localhost:8002`. Supports
auto, truck, bicycle, and pedestrian costing. Queryable by any local script.

## Three actions

| Action | Command | Effect |
|--------|---------|--------|
| **Serve** (default) | `docker compose up -d` | Serves cached tiles. No download, no rebuild. Instant. |
| **Build** (once) | `scripts/build.sh` | Downloads the USA PBF and builds tiles. Hours; ~100+ GB disk. |
| **Rebuild** (on demand) | `scripts/rebuild.sh` | Clears cache, fetches the **newest** map, rebuilds. |

Nothing downloads or rebuilds automatically — you are always the trigger.

## Setup

```bash
cp .env.example .env        # adjust VALHALLA_PORT / PBF_URL if needed
scripts/build.sh            # one-time: download + build tiles (hours)
docker compose logs -f valhalla   # watch until tiles are loaded
```

After the build, the API is live. Routine restarts just serve the cache:

```bash
docker compose up -d
```

## Refresh to the newest map

```bash
scripts/rebuild.sh          # destructive: clears cache, rebuilds from latest
```

## Querying

Health check:

```bash
curl http://localhost:8002/status
```

Truck route (curl):

```bash
curl http://localhost:8002/route -d '{
  "locations":[{"lat":41.8781,"lon":-87.6298},{"lat":39.7684,"lon":-86.1581}],
  "costing":"truck",
  "units":"miles"
}'
```

Python (see `examples/route_truck.py`):

```bash
pip install -r examples/requirements.txt
python examples/route_truck.py
```

Other endpoints: `/route`, `/sources_to_targets` (matrix), `/isochrone`,
`/optimized_route`. Pass `"costing":"truck"` plus optional
`costing_options.truck` (height, weight, axle_load, length, width, hazmat).

## Requirements / notes

- First build needs **~100+ GB free disk**, several GB RAM, and a few hours.
- The service is unavailable during a build/rebuild.
- `custom_files/` holds the PBF + tiles and is git-ignored — never committed.
````

- [ ] **Step 2: Verify README renders the key commands**

Run: `grep -E "scripts/build.sh|docker compose up -d|costing.*truck" README.md`
Expected: matches for the build script, serve command, and truck costing example.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add operations and query guide"
```

---

### Task 5 (optional, requires Docker host): live end-to-end smoke test

Only runnable on a machine with Docker and the disk/time budget for a full
build. Skip in constrained environments; do not block earlier tasks on it.

- [ ] **Step 1: Build tiles**

Run: `scripts/build.sh` then `docker compose logs -f valhalla` until tiles load.

- [ ] **Step 2: Verify status**

Run: `curl -s http://localhost:8002/status`
Expected: JSON including `"tileset_last_modified"` / version info (tiles loaded).

- [ ] **Step 3: Verify a truck route**

Run: `python examples/route_truck.py`
Expected: prints a distance (~180 mi) and time for Chicago→Indianapolis.

- [ ] **Step 4: Verify serve-mode does not rebuild**

Run: `docker compose down && docker compose up -d && docker compose logs valhalla | grep -i "serve"`
Expected: logs show it serves existing tiles; no download/build lines.

---

## Self-Review

- **Spec coverage:** Serve/build/rebuild (Tasks 1-2), localhost:8002 (Task 1), truck costing (Tasks 3-4), example client (Task 3), README ops notes + git-ignore of `custom_files/` (Tasks 1, 4), verification (Task 5). All spec sections mapped.
- **Placeholder scan:** No TBD/TODO; all scripts and configs are complete and literal.
- **Type consistency:** `route_truck(start, end, base_url)` defined and called consistently; env var names (`FORCE_REBUILD`, `USE_TILES_IGNORE_PBF`, `VALHALLA_PORT`, `PBF_URL`) consistent across compose, scripts, and docs.
- **Note:** elevation default is `False` in both `.env.example` and compose, matching the spec.
