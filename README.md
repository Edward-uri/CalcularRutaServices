# OSRM self-hosted (Chiapas) — Servicio de cálculo de ruta de ViajeSeguro

Despliegue del motor de ruteo **OSRM** que consume el backend (`BackendViajeseguro`)
para calcular distancia/tiempo reales sobre la red vial. Es un **servicio aparte**
(contenedor Docker), no código del backend.

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

## Qué hace por dentro

OSRM no se "programa": se **alimenta con datos** y se sirve. El `docker-entrypoint.sh`
hace el pipeline **una sola vez** y deja el resultado en el volumen `osrm-data`:

1. Descarga `mexico-latest.osm.pbf` de Geofabrik (~1.5 GB).
2. Recorta a Chiapas con `osmium extract -b <BBOX>` (queda un pbf chico).
3. Preprocesa con el pipeline **MLD**: `osrm-extract -p car.lua` → `osrm-partition` → `osrm-customize`.
4. Sirve: `osrm-routed --algorithm mld chiapas.osrm` en `:5000`.

En reinicios siguientes detecta el archivo `chiapas.ready` en el volumen y **arranca al
instante** (no re-descarga ni re-procesa).

## Archivos

| Archivo | Para qué |
|---|---|
| `Dockerfile` | Imagen = `osrm/osrm-backend:v5.25.0` + `osmium-tool` + `curl`. |
| `docker-entrypoint.sh` | Preprocesa-una-vez y luego sirve. |
| `docker-compose.yml` | Servicio `osrm` con volumen persistente y healthcheck. |
| `.env.example` | Variables (URL de datos, BBOX, perfil, flags). |
| `.gitignore` / `.dockerignore` | Excluyen los datos OSM (pesados). |
| `.gitattributes` | Fuerza LF en `*.sh`. |

## Requisitos

- Docker (con `docker compose`).
- **Disco:** ~5 GB libres durante el preprocesado (México 1.5 GB + intermedios). Tras
  terminar se borra el pbf de México (salvo `KEEP_SOURCE_PBF=true`); el `.osrm` de
  Chiapas pesa poco.
- **RAM:** baja, porque se procesa solo Chiapas (no todo México).

## Despliegue en Coolify (recomendado)

1. **Crear recurso** en el mismo proyecto del backend → tipo **Docker Compose**, apuntando
   a este repo/carpeta (que contiene `docker-compose.yml`).
2. **Variables de entorno:** los defaults (Chiapas) ya sirven. Ajusta `BBOX` si amplías
   cobertura.
3. **Volumen persistente:** Coolify mantiene el named volume `osrm-data` entre redeploys,
   así que el preprocesado se hace **una sola vez**.
4. **Deploy.** La **primera vez tarda** (descarga + preprocesado): puede estar varios
   minutos en *unhealthy* — es normal, el `start_period` del healthcheck da 30 min de
   margen. Mientras tanto el backend simplemente usa Haversine.
5. **Conectar con el backend (red interna):** asegúrate de que el contenedor OSRM y el
   backend estén en la **misma red** de Coolify (opción *Connect To Predefined Network* /
   misma red del proyecto). El hostname del servicio es `osrm` (definido como
   `container_name`).
6. **Configurar el backend:** en el env de `BackendViajeseguro` pon
   `OSRM_URL=http://osrm:5000` y **redeploy** del backend.

> El 5000 queda solo en `expose` (interno). No agregues `ports` en producción.

## Prueba local (opcional)

```bash
cp .env.example .env
# Descomenta el bloque `ports` en docker-compose.yml para poder llegar desde el host.
docker compose up --build
```

La primera corrida descarga y preprocesa (paciencia). Cuando veas
`Sirviendo en :5000`, valida desde el host:

```bash
curl "http://localhost:5000/route/v1/driving/-93.095,16.62;-93.098,16.626?overview=false"
```

Debe responder `{"code":"Ok","routes":[{ ... "distance": <m>, "duration": <s> ...}], ...}`.

## Validación en Coolify (desde el contenedor del backend)

```bash
curl "http://osrm:5000/route/v1/driving/-93.095,16.62;-93.098,16.626?overview=false"
```

`code: Ok` con `distance`/`duration` ⇒ el backend ya calculará tarifa con distancia real
de calle para viajes sin zona destino. **Criterio de aceptación cumplido.**

## Operación

**Refrescar el mapa (datos OSM nuevos):** pon `FORCE_REBUILD=true`, redeploy (re-descarga
y re-procesa), y al terminar **regrésalo a `false`** para que no reconstruya en cada
arranque.

**Ampliar cobertura (más allá de Chiapas):** cambia `BBOX`
(`minLon,minLat,maxLon,maxLat`) y haz `FORCE_REBUILD=true` una vez. A más área, más disco
y RAM en el preprocesado.

**Cambiar de vehículo:** `PROFILE=/opt/car.lua` por default. Existen `/opt/bicycle.lua` y
`/opt/foot.lua` en la imagen. Para un perfil de moto a la medida habría que montar un
`.lua` propio (fuera de alcance del MVP).

## Troubleshooting

| Síntoma | Causa / arreglo |
|---|---|
| `bad interpreter` / `no such file` al iniciar | El `.sh` quedó con CRLF. `.gitattributes` lo fuerza a LF; re-clona o normaliza con `git add --renormalize .`. |
| Queda *unhealthy* varios minutos al desplegar | Normal en la 1ª vez (descarga + preprocesado). Espera; el `start_period` es 30 min. |
| El backend no encuentra `osrm` (DNS) | OSRM y backend no comparten red en Coolify. Conéctalos a la misma red; verifica con `curl http://osrm:5000/...` desde el contenedor del backend. |
| Sin espacio en disco durante el build | Necesitas ~5 GB libres. Mantén `KEEP_SOURCE_PBF=false` para que borre el pbf de México al terminar. |
| Quiero re-preprocesar desde cero | `FORCE_REBUILD=true` (limpia `.osrm*` y `.ready`), redeploy, luego `false`. |

## Apéndice — preprocesado manual con Docker plano

Si prefieres generar el `.osrm` a mano (sin el entrypoint), con la imagen oficial:

```bash
# 1. Descargar y recortar (necesitas osmium instalado o usar un contenedor con osmium)
wget https://download.geofabrik.de/north-america/mexico-latest.osm.pbf
osmium extract -b -94.2,14.5,-90.3,17.99 mexico-latest.osm.pbf -o chiapas.osm.pbf

# 2. Preprocesar con la imagen oficial (monta el cwd en /data)
docker run --rm -v "$PWD:/data" osrm/osrm-backend:v5.25.0 osrm-extract -p /opt/car.lua /data/chiapas.osm.pbf
docker run --rm -v "$PWD:/data" osrm/osrm-backend:v5.25.0 osrm-partition /data/chiapas.osrm
docker run --rm -v "$PWD:/data" osrm/osrm-backend:v5.25.0 osrm-customize /data/chiapas.osrm

# 3. Servir
docker run --rm -p 5000:5000 -v "$PWD:/data" osrm/osrm-backend:v5.25.0 osrm-routed --algorithm mld /data/chiapas.osrm
```
