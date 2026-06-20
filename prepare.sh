#!/bin/sh
# osrm-prepare: descarga el pbf de México y lo recorta a la región con osmium.
# Es un init container: corre una vez por deploy y termina (exit 0).
set -eu

DATA_DIR="${DATA_DIR:-/data}"
GEOFABRIK_URL="${GEOFABRIK_URL:-https://download.geofabrik.de/north-america/mexico-latest.osm.pbf}"
# bbox = LEFT,BOTTOM,RIGHT,TOP (minLon,minLat,maxLon,maxLat). Default: Chiapas.
BBOX="${BBOX:--94.2,14.5,-90.3,17.99}"
NAME="${OSRM_NAME:-chiapas}"

SRC_PBF="${DATA_DIR}/mexico-latest.osm.pbf"
REGION_PBF="${DATA_DIR}/${NAME}.osm.pbf"
CLIPPED="${DATA_DIR}/${NAME}.clipped"   # sentinel: el recorte ya está completo y atómico
READY="${DATA_DIR}/${NAME}.ready"       # sentinel: osrm ya preprocesó (lo crea el otro servicio)

mkdir -p "$DATA_DIR"
cd "$DATA_DIR"

if [ "${FORCE_REBUILD:-false}" = "true" ]; then
  echo "[prepare] FORCE_REBUILD=true -> limpiando datos previos de '${NAME}'"
  rm -f "$READY" "$CLIPPED" "${NAME}".osrm* "$REGION_PBF"
fi

if [ -f "$CLIPPED" ]; then
  echo "[prepare] Recorte ya existe (${NAME}.clipped). Nada que hacer."
  exit 0
fi

if [ ! -f "$SRC_PBF" ]; then
  echo "[prepare] Descargando México desde Geofabrik (~1.5 GB)..."
  curl -fSL -o "$SRC_PBF" "$GEOFABRIK_URL"
fi

echo "[prepare] Recortando bbox ${BBOX} -> ${NAME}.osm.pbf"
# Escribe directo al nombre final (osmium detecta el formato por la extensión .osm.pbf).
# El orden lo garantiza el sentinel ${NAME}.clipped, que se crea DESPUÉS del recorte:
# osrm espera ese sentinel, así que nunca lee un pbf a medias.
osmium extract -b "$BBOX" "$SRC_PBF" -o "$REGION_PBF" --overwrite
touch "$CLIPPED"
echo "[prepare] Recorte listo."

if [ "${KEEP_SOURCE_PBF:-false}" != "true" ]; then
  echo "[prepare] Borrando ${SRC_PBF} para liberar disco (KEEP_SOURCE_PBF=true para conservarlo)."
  rm -f "$SRC_PBF"
fi
