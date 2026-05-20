FROM alpine:3.20

# postgresql16-client → pg_dump, redis → redis-cli, mc → MinIO client.
# crond is provided by busybox in the base image (container-safe, unlike dcron).
RUN apk add --no-cache postgresql16-client redis tzdata gzip \
 && ARCH="$(apk --print-arch | sed 's/x86_64/amd64/; s/aarch64/arm64/')" \
 && wget -q "https://dl.min.io/client/mc/release/linux-${ARCH}/mc" -O /usr/local/bin/mc \
 && chmod +x /usr/local/bin/mc

COPY backup.sh /usr/local/bin/backup.sh
COPY crontab /etc/crontabs/root
RUN chmod +x /usr/local/bin/backup.sh

CMD ["crond", "-f", "-l", "8", "-c", "/etc/crontabs"]
