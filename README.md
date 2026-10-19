# docker

Two images every Noria Labs database stack runs, built and kept current by
GitHub Actions and published to GHCR, plus the local OrbStack stacks that use
them.

- `postgres.Dockerfile` — PostgreSQL 18 on Debian trixie with pgvector compiled
  in, published as `ghcr.io/thekiharani/postgres`. Runs on every host and
  locally.
- `pg-backup.Dockerfile` and `pg-backup` — the backup sidecar beside each
  Postgres: hourly `pg_dump` of every database to Cloudflare R2 with hourly,
  daily and weekly retention and verified restores, published as
  `ghcr.io/thekiharani/pg-backup`.
- `compose.yml` — the local **noria** stack: MariaDB, PostgreSQL with pgvector,
  Redis and Mailpit, on the external `norialabs` network.
- `compose-db.yml` — reference only, never run. It keeps the older MySQL and
  smartfin service definitions to copy from.

Both images are public. Neither is built locally: a push to `main` that touches
an image's files publishes it, and a daily check rebuilds it when anything it is
made from has moved upstream.

## Local stack

Everything in `compose.yml` is driven from `.env`, which is not committed:
images, ports, database names and credentials. The only literals in the file
are the container ports on the right-hand side of each mapping, which the
images fix.

| variable | value | used by |
|---|---|---|
| `DB_USER` / `DP_PASS` | shared | mariadb, postgres, redis |
| `MARIADB_IMAGE` / `MARIADB_PORT` / `MARIADB_DATABASE` | `mariadb:13.0`, 3326, `norialabs` | mariadb |
| `POSTGRES_IMAGE` / `POSTGRES_PORT` / `POSTGRES_DB` | `ghcr.io/thekiharani/postgres:18-trixie`, 5452, `norialabs` | postgres |
| `REDIS_IMAGE` / `REDIS_PORT` | `redis:8.10-trixie`, 6399 | redis |
| `MAILPIT_IMAGE` / `MAILPIT_PORT` / `MAILPIT_SMTP_PORT` | `axllent/mailpit`, 8035, 1035 (loopback only) | mailpit |
| `MYSQL_IMAGE` / `MYSQL_PORT` / `MYSQL_DATABASE` | `mysql:8.4`, 3326, `norialabs` | `compose-db.yml` only |

Host ports are offset by +20 from their defaults so several stacks can coexist
(5432→5452, 6379→6399, 3306→3326). Mailpit's web UI is the exception, on 8035
as it always has been.

Use major.minor image tags to follow patch updates within the chosen release
series, with the Trixie flavor where available. MariaDB 13.0 has no official
Trixie flavor; `mariadb:13.0` uses Ubuntu Resolute.

MariaDB uses the external `noria_mariadb_data` volume, mounted at
`/var/lib/mysql`. Create it before the first start:

    docker volume create noria_mariadb_data
    docker compose pull noria_mariadb
    docker compose up -d --wait noria_mariadb

Connect from the host at `localhost:3326`, or from the `norialabs` network at
`noria_mariadb:3306`, using `MARIADB_DATABASE`, `DB_USER` and `DP_PASS` from `.env`.

## Postgres with pgvector

`postgres.Dockerfile` compiles pgvector from source on the official
`postgres:18-trixie` and copies only the built extension (~800 kB: the stripped
library, its LLVM bitcode for JIT inlining, and the control and upgrade SQL)
onto a clean copy of that image, so compilers never reach the final image. The
release tarball is pinned by `PGVECTOR_SHA256` and BuildKit refuses it on a
mismatch; the bump pull request updates the version and the checksum together.
It is built without `-march=native`, so it runs on any CPU of its architecture.

GitHub Actions (`.github/workflows/postgres.yml`) builds it for amd64 and arm64,
each on its own native Ubuntu 26.04 runner, and joins them into one
multi-platform tag. Don't build it locally.

It rebuilds only when the image would change: a push that changes
`postgres.Dockerfile`, or a check that finds upstream has moved. The check runs
every day at 04:17 UTC and on any push that changes only the workflow; pushes
that touch nothing else run nothing. It rebuilds when it finds:

- **Postgres or Debian:** the current `postgres:18-trixie` digest differs from
  the one the published image was built on. It rebuilds on the new base.
- **pgvector:** a newer release than `PGVECTOR_VERSION`. It opens a pull request
  bumping it, and merging that builds the new version like any Dockerfile change.

Each image records what it was built from in its labels:
`org.opencontainers.image.base.digest`, `com.github.thekiharani.pgvector.version`
and `org.opencontainers.image.revision`. That is how the check knows what is
published. Run the workflow from the Actions tab to check now, and tick
**force** to rebuild regardless.

| tag | points at |
|---|---|
| `latest`, `18-trixie` | the newest build, including base-image rebuilds |
| `18-trixie-<short sha>` | the build of that commit, including pgvector bumps; never moved |

Set `POSTGRES_IMAGE` to `18-trixie` to follow updates, or to a sha tag to hold
still. Then:

    docker compose pull noria_postgres && docker compose up -d noria_postgres

The image is a drop-in replacement for `postgres:18-trixie` and
`pgvector/pgvector:pg18-trixie`: same entrypoint, environment variables and
data directory, so an existing volume carries over.

### Upgrading pgvector

The daily check opens a pull request for each new release; to move sooner, edit
`PGVECTOR_VERSION` and push. Once the new image is running, update the extension in every
database that has it (`template1` included, so new databases start current):

    ALTER EXTENSION vector UPDATE;

### Upgrading Debian

A new glibc can change how text sorts, and Postgres then warns of a
"collation version mismatch" on connect. Rebuild the indexes, then record the
new version, in each database it names:

    REINDEX DATABASE <db>;
    ALTER DATABASE <db> REFRESH COLLATION VERSION;

## Postgres backups

`pg-backup.Dockerfile` builds `ghcr.io/thekiharani/pg-backup` on
`gcr.io/distroless/base-debian13`, which brings only glibc, OpenSSL, zlib, CA
certificates and tzdata. A throwaway `debian:trixie-slim` stage installs
`postgresql-client-18` from PGDG, after checking the signing key's fingerprint,
and stages what the runtime needs: the seven client binaries (`pg_dump`,
`pg_dumpall`, `pg_restore`, `psql`, `pg_isready`, `createdb`, `dropdb`), the
shared libraries `ldd` says they need beyond what distroless already has, and a
static busybox exposing only the fifteen applets the script calls. A Go stage
compiles `rclone` from the pinned release tag with only the `s3` and `local`
backends and only the eleven subcommands the script and its operator use, which
is a fraction of the stock binary. There is no package manager, no perl, no
`pg_wrapper` and no shell beyond busybox `sh`; the script is POSIX sh. It runs
as distroless's `nonroot` user (uid 65532) and needs no capabilities.

Every hour at `BACKUP_MINUTE` the `pg-backup` script dumps the roles and every
database on the server, checks each archive with `pg_restore --list`, writes a
`manifest.sha256`, uploads the set to `<prefix>/hourly/<date>/<HHMM>` and uploads
the manifest last, so a run that died mid-upload has no manifest. At
`BACKUP_DAILY_HOUR` it also copies that run server-side to `daily/<date>`, and on
Sundays to `weekly/<date>`. Each tier is then pruned to its own age. Dumps use
custom format with zstd compression.

Retention is driven entirely by environment, as rclone age strings. Empty
disables a tier.

| variable | default | meaning |
|---|---|---|
| `BACKUP_R2_BUCKET` | required | bucket name |
| `BACKUP_PREFIX` | `postgres` | path inside the bucket; every host uses `<hostname>/postgres` |
| `BACKUP_REMOTE` | `r2` | rclone remote name, configured through `RCLONE_CONFIG_<REMOTE>_*` |
| `BACKUP_MINUTE` | `15` | minute past each hour to run |
| `BACKUP_KEEP_HOURLY` | `48h` | age at which hourly runs are deleted |
| `BACKUP_KEEP_DAILY` | `30d` | age at which daily copies are deleted |
| `BACKUP_KEEP_WEEKLY` | `12w` | age at which weekly copies are deleted |
| `BACKUP_DAILY_HOUR` | `0` | UTC hour whose run is promoted to daily and weekly |
| `BACKUP_VERIFY_DAY` | off | ISO weekday (1 Monday to 7 Sunday) on which the daily run also restores every dump into a scratch database |
| `BACKUP_EXCLUDE_DBS` | none | extended regex; matching database names are skipped |
| `BACKUP_HEARTBEAT_URL` | none | URL fetched after each successful run, for a dead-man's switch |
| `PGHOST` / `PGUSER` / `PGPASSWORD` | | the usual libpq variables; the user needs `CREATEDB` for verification |

Subcommands, all run through `docker exec pg-backup pg-backup ...`:

| command | does |
|---|---|
| `once` | one run now; `once --verify` (or `verify`) also restores each dump into `pgbackup_verify` and drops it |
| `list [tier]` | the stamps held in `hourly` (default), `daily` or `weekly` |
| `restore <tier>/<stamp> <db> [target]` | downloads that database's dump, checks it against the manifest and restores it into `target` (created if missing; defaults to `db`) |
| `health` | the container healthcheck: Postgres reachable, no failed run, and a success or start within the last 125 minutes |

The service as every host runs it, in `~/docker/db/compose.yml` beside
`postgres` and `redis`, with the prefix set to that host's name:

    backup:
      image: ghcr.io/thekiharani/pg-backup:18-trixie
      container_name: pg-backup
      restart: unless-stopped
      environment:
        PGHOST: postgres
        PGUSER: ${POSTGRES_USER}
        PGPASSWORD: ${POSTGRES_PASSWORD}
        PGDATABASE: postgres
        BACKUP_R2_BUCKET: ${BACKUP_R2_BUCKET}
        BACKUP_PREFIX: norialabs-vm1/postgres
        BACKUP_MINUTE: "15"
        BACKUP_KEEP_HOURLY: 48h
        BACKUP_KEEP_DAILY: 30d
        BACKUP_KEEP_WEEKLY: 12w
        BACKUP_VERIFY_DAY: "7"
        RCLONE_CONFIG_R2_TYPE: s3
        RCLONE_CONFIG_R2_PROVIDER: Cloudflare
        RCLONE_CONFIG_R2_ENDPOINT: ${BACKUP_R2_ENDPOINT}
        RCLONE_CONFIG_R2_ACCESS_KEY_ID: ${BACKUP_R2_ACCESS_KEY_ID}
        RCLONE_CONFIG_R2_SECRET_ACCESS_KEY: ${BACKUP_R2_SECRET_ACCESS_KEY}
      depends_on:
        postgres:
          condition: service_healthy
      networks: [norialabs]
      security_opt: [no-new-privileges:true]
      cap_drop: [ALL]
      logging:
        driver: json-file
        options: { max-size: "10m", max-file: "5" }

The image carries its own healthcheck and sets `RCLONE_CONFIG=/dev/null`, so the
service needs neither. The bucket holds nothing but `<hostname>/postgres/` prefixes,
each with only `hourly/`, `daily/` and `weekly/` beneath it. To remove anything
else by hand, use `rclone delete <path>` from inside the container; the trimmed
rclone has no `purge`, and on S3 deleting every object under a path is the same
thing.

GitHub Actions (`.github/workflows/pg-backup.yml`) builds it exactly like the
Postgres image: amd64 and arm64 on native runners, joined into one tag, and only
when something would change. The check runs daily at 04:41 UTC and on any push
that changes only the workflow. It rebuilds when the Dockerfile or the script
changes, when the distroless, `debian:trixie-slim` or `golang:1-trixie` digest
moves (a Go toolchain update changes the TLS and HTTP code compiled into rclone),
or when PGDG publishes a newer `postgresql-client-18`. A new rclone release opens
a pull request bumping `RCLONE_VERSION`. The labels
`org.opencontainers.image.base.digest`, `com.github.thekiharani.build-base.digest`,
`com.github.thekiharani.go-base.digest`,
`com.github.thekiharani.postgresql-client.version` and
`com.github.thekiharani.rclone.version` record what is published.

| tag | points at |
|---|---|
| `latest`, `18-trixie` | the newest build, including base and client rebuilds |
| `18-trixie-<short sha>` | the build of that commit; never moved |

## Pinning

Tags move. Once a stack is working, lock an image to its digest:

    docker image inspect redis:8.10-trixie \
      --format '{{index .RepoDigests 0}}'

and paste the result into `.env` in place of the tag. The images all come from
there, not from `compose.yml`.

## Protection

Only the owner pushes to `main` and `dev`. Anyone else opens a pull request,
which needs the owner's approval; that is also how the pgvector and rclone
bumps arrive, since GitHub won't let a personal repository exempt the Actions
bot. No one,
the owner included, can force-push or delete either branch. Workflows from
outside contributors wait for approval, and only GitHub's and Docker's actions
may run.
