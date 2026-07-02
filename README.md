# OSM Valhalla — USA Routing Service

Self-hosted [Valhalla](https://github.com/valhalla/valhalla) routing engine
covering the continental USA, served at `http://localhost:8002`. Supports
auto, truck, bicycle, and pedestrian costing. Queryable by any local script.

## Three actions

| Action | Command | Effect |
|--------|---------|--------|
| **Serve** (default) | `docker compose up -d` | Serves cached tiles **(after the initial build)**. No download, no rebuild. Instant. |
| **Build** (once) | `scripts/build.sh` | Downloads the USA PBF and builds tiles. Hours; ~100+ GB disk. |
| **Rebuild** (on demand) | `scripts/rebuild.sh` | Clears cache, fetches the **newest** map, rebuilds. |

After the initial build, nothing downloads or rebuilds automatically — you are always the trigger. **Run `scripts/build.sh` before your first `docker compose up`**: an `up` with no tiles present will auto-download and build (hours).

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

## Packaging

The service image is published to this repo's GitHub Container Registry as
`ghcr.io/rytisss/osm_valhalla` by `.github/workflows/docker-publish.yml`
— a thin wrapper pinning `gis-ops/docker-valhalla` (see `Dockerfile`). It is
rebuilt on every push to `main`, on `v*` tags, and via manual dispatch.

After the **first** publish, make the package public (repo → Packages →
package settings → visibility), or `docker compose pull` will need a GHCR
login. To run against upstream instead, set `VALHALLA_IMAGE` in `.env`.

## Requirements / notes

- First build needs **~100+ GB free disk**, several GB RAM, and a few hours.
- The service is unavailable during a build/rebuild.
- `custom_files/` holds the PBF + tiles and is git-ignored — never committed.
