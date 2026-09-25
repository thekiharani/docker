# syntax=docker/dockerfile:1.7
ARG PG_MAJOR=18
ARG PG_BASE=postgres:${PG_MAJOR}-trixie

FROM ${PG_BASE} AS pgvector
ARG PG_MAJOR
ARG PGVECTOR_VERSION=0.8.6
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
 && apt-get update \
 && apt-get install -y --no-install-recommends build-essential ca-certificates curl postgresql-server-dev-${PG_MAJOR}
WORKDIR /src
RUN curl -fsSL "https://github.com/pgvector/pgvector/archive/refs/tags/v${PGVECTOR_VERSION}.tar.gz" \
    | tar -xz --strip-components=1
# OPTFLAGS="" drops -march=native, which would tie the binary to the build machine's CPU.
RUN make -j"$(nproc)" OPTFLAGS="" \
 && make install DESTDIR=/out OPTFLAGS="" \
 && find /out -name '*.so' -exec strip --strip-unneeded {} +

FROM ${PG_BASE}
COPY --link --from=pgvector /out/ /
LABEL org.opencontainers.image.source=https://github.com/thekiharani/docker \
      org.opencontainers.image.description="PostgreSQL on Debian trixie with pgvector" \
      org.opencontainers.image.licenses=PostgreSQL
