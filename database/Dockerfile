# MariaDB with EMERSE's settings and schema baked in, so escher needs no release files.
# Build context is the repo root (build.sh), for assets/ (fetched by download.sh).
FROM docker.io/library/mariadb:11.4

COPY database/conf.d/ /etc/mysql/conf.d/
# first start on an empty volume only: schema + demo rows, then lock the demo accounts
COPY assets/fresh-install-v7.2.1.maria.sql /docker-entrypoint-initdb.d/10-fresh-install.sql
COPY database/initdb/90-chi-lockdown.sql /docker-entrypoint-initdb.d/
