# syntax=docker/dockerfile:1.7
ARG PG_MAJOR=18
ARG BUILD_BASE=debian:trixie-slim
ARG RUNTIME_BASE=gcr.io/distroless/base-debian13:nonroot
ARG GO_BASE=golang:1-trixie
ARG RCLONE_VERSION=1.75.2

FROM ${GO_BASE} AS rclone
ARG RCLONE_VERSION
WORKDIR /src
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    curl -fsSL "https://github.com/rclone/rclone/archive/refs/tags/v${RCLONE_VERSION}.tar.gz" | tar -xz --strip-components=1 \
 && { echo 'package all'; echo 'import ('; for b in local s3; do echo "_ \"github.com/rclone/rclone/backend/$b\""; done; echo ')'; } > backend/all/all.go \
 && { echo 'package all'; echo 'import ('; for c in check copy copyto copyurl delete ls lsd lsf lsl size version; do echo "_ \"github.com/rclone/rclone/cmd/$c\""; done; echo ')'; } > cmd/all/all.go \
 && CGO_ENABLED=0 go build -trimpath -ldflags '-s -w' -tags noselfupdate -o /usr/local/bin/rclone . \
 && rclone version --check=false

FROM ${BUILD_BASE} AS client
ARG PG_MAJOR
ARG PGDG_FINGERPRINT=B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
 && apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
 && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /tmp/pgdg.asc \
 && gpg --show-keys --with-colons /tmp/pgdg.asc | grep -q "^fpr:.*:${PGDG_FINGERPRINT}:" \
 && install -D -m 644 /tmp/pgdg.asc /etc/apt/keyrings/pgdg.asc \
 && echo "deb [signed-by=/etc/apt/keyrings/pgdg.asc] https://apt.postgresql.org/pub/repos/apt trixie-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends busybox-static postgresql-client-${PG_MAJOR}
# The runtime base already carries glibc, OpenSSL and zlib; copying those over its own would mix package builds.
RUN set -e \
 && mkdir -p /out/usr/bin /out/usr/local/bin \
 && cp /bin/busybox /out/usr/bin/busybox \
 && for applet in sh basename cat date find grep ls mktemp mv rm sha256sum sleep touch tr wc; do ln -s busybox "/out/usr/bin/$applet"; done \
 && for tool in pg_dump pg_dumpall pg_restore pg_isready psql createdb dropdb; do cp "/usr/lib/postgresql/${PG_MAJOR}/bin/$tool" /out/usr/local/bin/; done \
 && for lib in $(ldd /out/usr/local/bin/* | awk '/=>/ { print $3 }' | sort -u | sed 's#^/lib/#/usr/lib/#'); do \
      if dpkg -S "$lib" | grep -qE '^(libc6|libssl3t64|zlib1g):'; then continue; fi; \
      real=$(readlink -f "$lib"); \
      cp -a --parents "$real" /out; \
      [ "$real" = "$lib" ] || cp -a --parents "$lib" /out; \
    done

FROM ${RUNTIME_BASE}
COPY --link --from=rclone /usr/local/bin/rclone /usr/local/bin/
COPY --link --from=client /out/ /
COPY --chmod=755 pg-backup /usr/local/bin/pg-backup
RUN ["/bin/sh", "-c", "pg_dump --version && pg_dumpall --version && pg_restore --version && pg_isready --version && psql --version && createdb --version && dropdb --version && rclone version --check=false"]
ENV LANG=C.UTF-8 RCLONE_CONFIG=/dev/null PGCONNECT_TIMEOUT=10
USER nonroot
HEALTHCHECK --interval=5m --timeout=10s --start-period=10s --start-interval=2s --retries=1 CMD ["pg-backup", "health"]
ENTRYPOINT ["pg-backup"]
LABEL org.opencontainers.image.source=https://github.com/thekiharani/docker \
      org.opencontainers.image.description="Hourly pg_dump of every database to S3-compatible storage with hourly, daily and weekly retention"
