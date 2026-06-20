# OSRM self-hosted (Chiapas) — Servicio de cálculo de ruta de ViajeSeguro

Despliegue del motor de ruteo **OSRM** que consume el backend (`BackendViajeseguro`)
para calcular distancia/tiempo reales sobre la red vial. Es un **servicio aparte**
(contenedores Docker), no código del backend.

> Spec de origen: `2026-06-20-calculo-ruta-osrm-design.md` (Parte B). La Parte A (el
> adapter `OsrmRouteEstimator` que llama a este servicio) ya está en el backend.

## Cómo encaja

```
┌──────────────── Coolify (red interna) ────────────────┐
│                                                        │
│  BackendViajeseguro                  OSRM (este repo)  │
│  ┌────────────────────────┐          ┌──────────────┐  │
│  │ OsrmRouteEstimator ─────┼──HTTP─────→ osrm-routed │  │
│  │   fallback: Haversine   │  interno  │   :5000     │  │
│  └────────────────────────┘           └──────────────┘  │
│        OSRM_URL=http://osrm:5000                       │
└────────────────────────────────────────────────────────┘
```

- El puerto **5000 NO se expone público**: solo lo ve el backend por la red interna.
- Si OSRM se cae o `OSRM_URL` está vacía, el backend usa Haversine (línea recta). El
  ruteo real es una mejora, nunca un punto único de falla.

## Cómo funciona por dentro (dos servicios, un volumen)

OSRM no se "programa": se **alimenta con datos** y se sirve. El trabajo se parte en dos
contenedores que comparten el volumen `osrm-data`:

1. **`osrm-prepare`** (base Debian moderna, con `osmium` + `curl`):
   - Descarga `mexico-latest.osm.pbf` de Geofabrik (~1.5 GB).
   - Recorta a la región con `osmium extract -b <BBOX>` y deja `chiapas.osm.pbf`.
   - Corre **una sola vez** y termina (init container).
2. **`osrm`** (imagen oficial de OSRM, sin modificar paquetes):
   - Espera el recorte, preprocesa con el pipeline **MLD**:
     `osrm-extract -p car.lua` → `osrm-partition` → `osrm-customize`.
   - Sirve: `osrm-routed --algorithm mld chiapas.osrm` en `:5000`.

Todo queda en el volumen `osrm-data` con dos sentinels: `chiapas.clipped` (recorte listo) y
`chiapas.ready` (preprocesado listo). En reinicios siguientes **arranca al instante** (no
re-descarga ni re-procesa).

> **¿Por qué dos imágenes?** La imagen oficial de OSRM está construida sobre Debian *stretch*
> (archivado): no se le puede `apt install` nada. Por eso `osmium` y la descarga viven en
> `osrm-prepare` (Debian moderno) y la imagen de OSRM se usa tal cual.

## Archivos

| Archivo | Para qué |
|---|---|
| `Dockerfile` | Imagen `osrm` = `osrm/osrm-backend:v5.25.0` + el entrypoint (sin `apt`). |
| `docker-entrypoint.sh` | Servicio osrm: espera el recorte, preprocesa y sirve. |
| `Dockerfile.prepare` | Imagen `osrm-prepare` = `debian:bookworm-slim` + `osmium-tool` + `curl`. |
| `prepare.sh` | Descarga México y recorta a la región. |
| `docker-compose.yml` | Los dos servicios + volumen persistente `osrm-data`. |
| `.env.example` | Variables (URL de datos, BBOX, perfil, flags). |
| `.gitignore` / `.dockerignore` | Excluyen los datos OSM (pesados). |
| `.gitattributes` | Fuerza LF en `*.sh`. |

## Requisitos

- Docker (con `docker compose`).
- **Disco:** ~5 GB libres durante el preprocesado (México 1.5 GB + intermedios). Al terminar
  se borra el pbf de México (salvo `KEEP_SOURCE_PBF=true`); el `.osrm` de Chiapas pesa poco.
- **RAM:** baja, porque se procesa solo Chiapas (no todo México).

## Despliegue en Coolify (recomendado)

1. **Crear recurso** en el mismo proyecto del backend → tipo **Docker Compose** (Git based:
   *Public Repository* o *Private with GitHub App*), apuntando a este repo.
2. **Build Pack = Docker Compose**, ubicación `/docker-compose.yml`.
3. **Variables de entorno:** los defaults (Chiapas) ya sirven. Ajusta `BBOX` si amplías
   cobertura.
4. **Volumen persistente:** confirma que Coolify mantiene el named volume `osrm-data` entre
   redeploys. ⚠️ Esto hace que el preprocesado ocurra **una sola vez**.
5. **Red interna:** activa **"Connect To Predefined Network"** en este recurso y en el backend,
   para que se resuelvan por nombre.
6. **No asignes dominio ni puerto público.** El compose usa solo `expose: 5000`.
7. **Deploy.** La **primera vez tarda** (descarga + preprocesado): en los logs verás
   `osrm-prepare` descargando y recortando, y luego `osrm` con
   `osrm-extract` → `osrm-partition` → `osrm-customize` → **`Sirviendo en :5000`**.
   Mientras tanto el backend usa Haversine sin errores.
8. **Configurar el backend:** en su env pon `OSRM_URL=http://osrm:5000` y **redeploy** del
   backend.

> `osrm-prepare` aparecerá como **exited/stopped** tras terminar: es lo esperado (corre una
> vez). El servicio que queda corriendo es `osrm`.

## Prueba local (opcional)

```bash
cp .env.example .env
# Descomenta el bloque `ports` del servicio osrm en docker-compose.yml para llegar desde el host.
docker compose up --build
```

La primera corrida descarga y preprocesa (paciencia). Cuando veas `Sirviendo en :5000`,
valida desde el host:

```bash
curl "http://localhost:5000/route/v1/driving/-93.095,16.62;-93.098,16.626?overview=false"
```

Debe responder `{"code":"Ok","routes":[{ ... "distance": <m>, "duration": <s> ...}], ...}`.

## Validación en Coolify (desde el contenedor del backend)

```bash
curl "http://osrm:5000/route/v1/driving/-93.095,16.62;-93.098,16.626?overview=false"
```

`code: Ok` con `distance`/`duration` ⇒ el backend ya calculará tarifa con distancia real de
calle para viajes sin zona destino. **Criterio de aceptación cumplido.**

## Operación

**Refrescar el mapa (datos OSM nuevos):** pon `FORCE_REBUILD=true`, redeploy (re-descarga y
re-procesa), y al terminar **regrésalo a `false`** para que no reconstruya en cada arranque.

**Ampliar cobertura (más allá de Chiapas):** cambia `BBOX`
(`minLon,minLat,maxLon,maxLat`) y haz `FORCE_REBUILD=true` una vez. A más área, más disco y
RAM en el preprocesado.

**Cambiar de vehículo:** `PROFILE=/opt/car.lua` por default. Existen `/opt/bicycle.lua` y
`/opt/foot.lua` en la imagen. Para un perfil de moto a la medida habría que montar un `.lua`
propio (fuera de alcance del MVP).

## Troubleshooting

| Síntoma | Causa / arreglo |
|---|---|
| Build falla en `apt-get` con exit 100 | No instales paquetes en la imagen de OSRM (Debian stretch archivada). Por eso `osmium` va en `osrm-prepare` (Debian moderno). |
| `bad interpreter` al iniciar | El `.sh` quedó con CRLF. `.gitattributes` lo fuerza a LF; re-clona o `git add --renormalize .`. |
| `osrm-prepare` aparece detenido | Normal: es init container, corre una vez y termina con exit 0. |
| El backend no encuentra `osrm` (DNS) | OSRM y backend no comparten red en Coolify. Conéctalos a la misma red; verifica con `curl http://osrm:5000/...` desde el contenedor del backend. |
| `osrm` se queda "Esperando el recorte" | `osrm-prepare` aún descarga/recorta (mira sus logs), o falló (revisa errores de descarga). |
| Reconstruye en cada deploy | El volumen `osrm-data` no quedó persistente. |
| Sin espacio en disco | Necesitas ~5 GB libres. Mantén `KEEP_SOURCE_PBF=false`. |

## Apéndice — preprocesado manual con Docker plano

Si prefieres generar el `.osrm` a mano:

```bash
# 1. Descargar y recortar (osmium en una base moderna)
docker run --rm -v "$PWD:/data" -w /data debian:bookworm-slim sh -c \
  "apt-get update && apt-get install -y --no-install-recommends osmium-tool curl ca-certificates && \
   curl -fSL -o mexico.osm.pbf https://download.geofabrik.de/north-america/mexico-latest.osm.pbf && \
   osmium extract -b -94.2,14.5,-90.3,17.99 mexico.osm.pbf -o chiapas.osm.pbf --overwrite"

# 2. Preprocesar con la imagen oficial de OSRM (monta el cwd en /data)
docker run --rm -v "$PWD:/data" osrm/osrm-backend:v5.25.0 osrm-extract -p /opt/car.lua /data/chiapas.osm.pbf
docker run --rm -v "$PWD:/data" osrm/osrm-backend:v5.25.0 osrm-partition /data/chiapas.osrm
docker run --rm -v "$PWD:/data" osrm/osrm-backend:v5.25.0 osrm-customize /data/chiapas.osrm

# 3. Servir
docker run --rm -p 5000:5000 -v "$PWD:/data" osrm/osrm-backend:v5.25.0 osrm-routed --algorithm mld /data/chiapas.osrm
```
