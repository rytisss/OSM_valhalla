# Thin wrapper over the upstream Valhalla image so this repository publishes
# its own pinned package to GHCR (ghcr.io/rytisss/osm_valhalla) instead of
# depending on the third-party `latest` tag at deploy time.
ARG VALHALLA_VERSION=3.5.1
FROM ghcr.io/gis-ops/docker-valhalla/valhalla:${VALHALLA_VERSION}
