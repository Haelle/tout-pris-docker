# Outils de manipulation de la base : le client sqlite3, la boucle de
# sauvegarde (backup.sh) et la restauration (restore.sh). Volontairement
# minuscule — la logique tient dans deux scripts shell relisibles sans
# documentation.
FROM alpine:3.22

RUN apk add --no-cache \
      sqlite \
      gzip \
      curl \
      tzdata

COPY backup.sh restore.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/backup.sh /usr/local/bin/restore.sh

WORKDIR /backups

ENTRYPOINT ["/usr/local/bin/backup.sh"]
CMD ["loop"]
