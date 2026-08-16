# Conteneur de sauvegarde : le client sqlite3, et une boucle (voir backup.sh).
# Volontairement minuscule — la logique tient dans un script shell relisible
# sans documentation.
FROM alpine:3.22

RUN apk add --no-cache \
      sqlite \
      gzip \
      curl \
      tzdata

COPY backup.sh /usr/local/bin/backup.sh
RUN chmod +x /usr/local/bin/backup.sh

WORKDIR /backups

ENTRYPOINT ["/usr/local/bin/backup.sh"]
CMD ["loop"]
