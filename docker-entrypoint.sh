#!/bin/sh
# Servicio osrm: espera el recorte que deja osrm-prepare, preprocesa el mapa una sola vez
# (extract/partition/customize) y sirve osrm-routed. NO descarga ni recorta (eso es osrm-prepare).
set -eu

DATA_DIR="${DATA_DIR:-/data}"
PROFILE="${PROFILE:-/opt/car.lua}"
NAME="${OSRM_NAME:-chiapas}"

REGION_PBF="${DATA_DIR}/${NAME}.osm.pbf"
OSRM_BASE="${DATA_DIR}/${NAME}.osrm"
CLIPPED="${DATA_DIR}/${NAME}.clipped"   # lo crea osrm-prepare cuando el recorte está listo
READY="${DATA_DIR}/${NAME}.ready"       # lo creamos aquí cuando el preprocesado termina

cd "$DATA_DIR"

if [ "${FORCE_REBUILD:-false}" = "true" ]; then
  rm -f "$READY"
fi

if [ ! -f "$READY" ]; then
  echo "[osrm] Esperando el recorte de osrm-prepare (${CLIPPED})..."
  i=0
  while [ ! -f "$CLIPPED" ]; do
    i=$((i + 1))
    if [ "$i" -gt 720 ]; then   # 720 * 5s = 60 min
      echo "[osrm] ERROR: osrm-prepare no produjo ${CLIPPED} tras 60 min. Revisa sus logs." >&2
      exit 1
    fi
    sleep 5
  done

  echo "[osrm] Recorte listo. osrm-extract (perfil ${PROFILE})"
  osrm-extract -p "$PROFILE" "$REGION_PBF"
  echo "[osrm] osrm-partition"
  osrm-partition "$OSRM_BASE"
  echo "[osrm] osrm-customize"
  osrm-customize "$OSRM_BASE"
  touch "$READY"
  echo "[osrm] Preprocesado completo."
fi

echo "[osrm] Sirviendo en :5000 (algoritmo mld) desde ${OSRM_BASE}"
exec osrm-routed --algorithm mld "$OSRM_BASE"
