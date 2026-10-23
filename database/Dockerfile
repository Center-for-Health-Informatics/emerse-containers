# MariaDB with EMERSE's settings and schema baked in, so escher needs no release files.
# Build context is the repo root (build.sh), for assets/ (fetched by download.sh).
FROM docker.io/library/mariadb:11.4
# from download.sh, via build.sh
ARG EMERSE_VERSION

COPY database/conf.d/ /etc/mysql/conf.d/
# first start on an empty volume only: schema + demo rows, then lock the demo accounts and
# relabel source5 as Cardiology
COPY assets/fresh-install-v${EMERSE_VERSION}.maria.sql /docker-entrypoint-initdb.d/10-fresh-install.sql
COPY database/initdb/90-chi-lockdown.sql database/initdb/91-chi-sources.sql /docker-entrypoint-initdb.d/
