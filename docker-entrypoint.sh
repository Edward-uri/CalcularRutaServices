#!/bin/sh
# Entrypoint de OSRM self-hosted para ViajeSeguro.
# Preprocesa el mapa UNA sola vez (descarga México -> recorta a la región ->
# extract/partition/customize) dentro del volumen /data, y luego sirve osrm-routed.
# En reinicios posteriores detecta el archivo "<name>.ready" y arranca directo.
set -eu

DATA_DIR="${DATA_DIR:-/data}"
GEOFABRIK_URL="${GEOFABRIK_URL:-https://download.geofabrik.de/north-america/mexico-latest.osm.pbf}"
# bbox = LEFT,BOTTOM,RIGHT,TOP (minLon,minLat,maxLon,maxLat). Default: Chiapas.
BBOX="${BBOX:--94.2,14.5,-90.3,17.99}"
PROFILE="${PROFILE:-/opt/car.lua}"
NAME="${OSRM_NAME:-chiapas}"

SRC_PBF="${DATA_DIR}/mexico-latest.osm.pbf"
REGION_PBF="${DATA_DIR}/${NAME}.osm.pbf"
OSRM_BASE="${DATA_DIR}/${NAME}.osrm"
READY="${DATA_DIR}/${NAME}.ready"

mkdir -p "$DATA_DIR"
cd "$DATA_DIR"

if [ "${FORCE_REBUILD:-false}" = "true" ]; then
  echo "[osrm] FORCE_REBUILD=true -> limpiando datos previos de '${NAME}'"
  rm -f "$READY" "${NAME}".osrm* "$REGION_PBF"
fi

if [ ! -f "$READY" ]; then
  echo "[osrm] Sin datos preprocesados. Construyendo (tarda; SOLO la primera vez)."

  if [ ! -f "$SRC_PBF" ]; then
    echo "[osrm] Descargando México desde Geofabrik (~1.5 GB)..."
    curl -fSL -o "$SRC_PBF" "$GEOFABRIK_URL"
  fi

  if [ ! -f "$REGION_PBF" ]; then
    echo "[osrm] Recortando bbox ${BBOX} -> ${NAME}.osm.pbf"
    osmium extract -b "$BBOX" "$SRC_PBF" -o "$REGION_PBF" --overwrite
  fi

  echo "[osrm] osrm-extract (perfil ${PROFILE})"
  osrm-extract -p "$PROFILE" "$REGION_PBF"
  echo "[osrm] osrm-partition"
  osrm-partition "$OSRM_BASE"
  echo "[osrm] osrm-customize"
  osrm-customize "$OSRM_BASE"

  touch "$READY"
  echo "[osrm] Preprocesado completo."

  if [ "${KEEP_SOURCE_PBF:-false}" != "true" ]; then
    echo "[osrm] Borrando ${SRC_PBF} para liberar disco (KEEP_SOURCE_PBF=true para conservarlo)."
    rm -f "$SRC_PBF"
  fi
fi

echo "[osrm] Sirviendo en :5000 (algoritmo mld) desde ${OSRM_BASE}"
exec osrm-routed --algorithm mld "$OSRM_BASE"
