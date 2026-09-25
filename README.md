# docker

Local service stacks, run on OrbStack, and the Postgres image they use.

- `compose.yml` — the **noria** stack: PostgreSQL with pgvector, Redis and
  Mailpit, on the external `norialabs` network. This is the one that runs.
- `compose-db.yml` — reference only, never run. It keeps the older MySQL and
  smartfin service definitions to copy from.
- `postgres.Dockerfile` — the image behind `noria_postgres`, published to
  `ghcr.io/thekiharani/postgres`.

Everything in `compose.yml` is driven from `.env`, which is not committed:
images, ports, database names and credentials. The only literals in the file
are the container ports on the right-hand side of each mapping, which the
images fix.

| variable | value | used by |
|---|---|---|
| `DB_USER` / `DP_PASS` | shared | postgres, redis |
| `POSTGRES_IMAGE` / `POSTGRES_PORT` / `POSTGRES_DB` | `ghcr.io/thekiharani/postgres:18-trixie`, 5452, `norialabs` | postgres |
| `REDIS_IMAGE` / `REDIS_PORT` | `redis:8.10-trixie`, 6399 | redis |
| `MAILPIT_IMAGE` / `MAILPIT_PORT` | `axllent/mailpit`, 8035 | mailpit |
| `MYSQL_IMAGE` / `MYSQL_PORT` / `MYSQL_DATABASE` | `mysql:8.4`, 3326, `norialabs` | `compose-db.yml` only |

Host ports are offset by +20 from their defaults so several stacks can coexist
(5432→5452, 6379→6399, 3306→3326). Mailpit's web UI is the exception, on 8035
as it always has been.

## Postgres with pgvector

`postgres.Dockerfile` compiles pgvector from source on the official
`postgres:18-trixie` and copies only the built extension (~630 kB) onto a clean
copy of that image, so compilers never reach the final image. It is built
without `-march=native`, so it runs on any CPU of its architecture.

GitHub Actions (`.github/workflows/postgres.yml`) builds it for amd64 and arm64,
each on its own native Ubuntu 26.04 runner, and joins them into one
multi-platform tag. Don't build it locally.

It rebuilds only when the image would change: a push that changes
`postgres.Dockerfile`, or a check that finds upstream has moved. The check runs
every day at 04:17 UTC and on any push that changes only the workflow; pushes
that touch nothing else run nothing. It rebuilds when it finds:

- **Postgres or Debian:** the current `postgres:18-trixie` digest differs from
  the one the published image was built on. It rebuilds on the new base.
- **pgvector:** a newer release than `PGVECTOR_VERSION`. It commits the bump to
  the Dockerfile, builds that commit, and opens an issue reminding you to run
  `ALTER EXTENSION vector UPDATE`.

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

The daily check bumps `PGVECTOR_VERSION` by itself; to move sooner, edit it
and push. Once the new image is running, update the extension in every
database that has it (`template1` included, so new databases start current):

    ALTER EXTENSION vector UPDATE;

### Upgrading Debian

A new glibc can change how text sorts, and Postgres then warns of a
"collation version mismatch" on connect. Rebuild the indexes, then record the
new version, in each database it names:

    REINDEX DATABASE <db>;
    ALTER DATABASE <db> REFRESH COLLATION VERSION;

## Pinning

Tags move. Once a stack is working, lock an image to its digest:

    docker image inspect redis:8.10-trixie \
      --format '{{index .RepoDigests 0}}'

and paste the result into `.env` in place of the tag. The images all come from
there, not from `compose.yml`.
