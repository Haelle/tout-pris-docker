# Conteneur de sauvegarde : embarque les clients SQLite et PostgreSQL, et
# tourne en boucle (voir backup.sh). Volontairement minuscule — la logique
# tient dans un script shell relisible sans documentation.
FROM alpine:3.22

RUN apk add --no-cache \
      sqlite \
      postgresql17-client \
      gzip \
      curl \
      tzdata

COPY backup.sh /usr/local/bin/backup.sh
RUN chmod +x /usr/local/bin/backup.sh

WORKDIR /backups

ENTRYPOINT ["/usr/local/bin/backup.sh"]
CMD ["loop"]
