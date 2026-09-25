# docker

Local service stacks, run on OrbStack.

- `compose.yml` — the **noria** stack: MySQL, PostgreSQL (pgvector), Redis,
  Mailpit. Joins the external `norialabs` network.
- `compose-db.yml` — the leaner **smartfin** stack: PostgreSQL + Redis on the
  external `smartfin` network, with external volumes.

Everything in `compose.yml` is driven from `.env` — images, ports, database
names and credentials. There are no literals in the file except the container
ports on the right-hand side of each mapping, which are fixed by the images.

| variable | value | used by |
|---|---|---|
| `DB_USER` / `DP_PASS` | shared | mysql, postgres, redis |
| `MYSQL_IMAGE` / `MYSQL_PORT` / `MYSQL_DATABASE` | `mysql:8.4`, 3326, `norialabs` | mysql |
| `POSTGRES_IMAGE` / `POSTGRES_PORT` / `POSTGRES_DB` | `pgvector/pgvector:pg18-trixie`, 5452, `norialabs` | postgres |
| `REDIS_IMAGE` / `REDIS_PORT` | `redis:8.10-trixie`, 6399 | redis |
| `MAILPIT_IMAGE` / `MAILPIT_PORT` | `axllent/mailpit`, 8035 | mailpit |

Host ports are offset by +20 from their defaults so several stacks can coexist
(3306→3326, 5432→5452, 6379→6399). One exception: Mailpit is on 8035 for the
web UI, which is what it has always been.

`compose-db.yml` is deliberately left as it was.

## Pinning

Tags move. Once a stack is working, lock an image to its digest:

    docker image inspect redis:8.10-trixie \
      --format '{{index .RepoDigests 0}}'

and paste the result into `.env` in place of the tag — the images all come
from there, not from `compose.yml`.

## Postgres with pgvector

`postgres.Dockerfile` builds pgvector from source on the official
`postgres:18-trixie` and copies only the built extension (~630 kB) onto a
clean copy of that image, so the compilers never reach the final image.

GitHub Actions publishes it as `ghcr.io/thekiharani/postgres:18-trixie` for
amd64 and arm64, each built on its own native runner, on every change to the
Dockerfile and every Monday so the base image's security fixes land without a
commit. Don't build it locally. To use it, set `POSTGRES_IMAGE` in `.env` to that tag.

Bump pgvector with `PGVECTOR_VERSION` in the Dockerfile. After
moving an existing volume to a newer pgvector, run `ALTER EXTENSION vector UPDATE;`.
