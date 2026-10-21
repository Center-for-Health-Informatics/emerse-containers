#!/bin/sh
# Nightly backup into $DATA_DIR/backups (cron on chi-escher, e.g. 02:30):
#   - MariaDB: a consistent mariadb-dump, gzipped, KEEP_DAYS kept
#   - Solr: a replication-handler snapshot of each core, KEEP_SNAPSHOTS kept
#
# Both hold PHI. Copy them off the host only to UC Health storage.
#
#   bin/backup.sh            database and Solr
#   bin/backup.sh --db-only  database only (the index can be rebuilt from the exports)
set -eu
cd "$(dirname "$0")/.."
compose=${COMPOSE:-docker compose}
KEEP_DAYS=${KEEP_DAYS:-14}
KEEP_SNAPSHOTS=${KEEP_SNAPSHOTS:-2}
stamp=$(date +%Y%m%d-%H%M%S)

# the dump is written inside the container, to the /backups mount, so the password never
# appears in a host process list
$compose exec -T database sh -c '
	set -eu
	umask 077
	mariadb-dump -u root -p"$(cat /run/secrets/mariadb_root_password)" \
		--single-transaction --routines --triggers --databases emerse \
		| gzip > "/backups/emerse-'"$stamp"'.sql.gz.part"
	mv "/backups/emerse-'"$stamp"'.sql.gz.part" "/backups/emerse-'"$stamp"'.sql.gz"
	find /backups -maxdepth 1 -name "emerse-*.sql.gz" -mtime +'"$KEEP_DAYS"' -delete
'
echo "database: backups/emerse-$stamp.sql.gz" >&2

[ "${1:-}" = --db-only ] && exit 0

for core in documents patient; do
	$compose exec -T solr curl -fsS -o /dev/null \
		"http://localhost:8983/solr/$core/replication?command=backup&location=/var/solr/data/backups&name=$core-$stamp&numberToKeep=$KEEP_SNAPSHOTS"
	echo "solr: backups/solr/snapshot.$core-$stamp (written in the background; see /solr/$core/replication?command=details)" >&2
done
