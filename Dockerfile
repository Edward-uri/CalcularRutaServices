# Sirve OSRM. Imagen oficial tal cual (trae osrm-extract/partition/customize/routed y los
# perfiles /opt/*.lua); solo le añadimos el entrypoint.
# NO instalamos paquetes: la base de esta imagen es Debian stretch (archivada), así que su
# apt está roto. La descarga + recorte con osmium los hace el servicio osrm-prepare, que usa
# una base Debian moderna.
FROM osrm/osrm-backend:v5.25.0

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# El mapa preprocesado vive aquí (volumen compartido con osrm-prepare).
VOLUME ["/data"]
EXPOSE 5000

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
