#!/bin/sh
# Prepare a host to run compose.yaml: secrets, the pinned CHI key and data directories.
# Safe to re-run; it never overwrites a secret or an existing index. Needs only this file,
# compose.yaml and .env: the images carry the release files.
#
#   ./deploy.sh          the solr image seeds an empty production index on first start
#   ./deploy.sh --demo   EMERSE's demo index with synthetic patients and notes (needs
#                        ./download.sh's assets, so a dev machine only)
set -eu
cd "$(dirname "$0")"

demo=false
[ "${1:-}" = --demo ] && demo=true

[ -f .env ] || { echo "no .env (copy .env.example)" >&2; exit 1; }
set -a; . ./.env; set +a
: "${DATA_DIR:?}"
CONFIG_DIR=${CONFIG_DIR:-./etc/local}
INDEXES_ZIP=assets/solr-indexes-7.2.0.zip
EMERSE_VERSION=$(sed -n 's/^EMERSE_VERSION=//p' download.sh 2>/dev/null || true)
if $demo; then
	for f in "assets/solr-plugin-$EMERSE_VERSION.jar" assets/solrconfig.xml "$INDEXES_ZIP"; do
		[ -f "$f" ] || { echo "missing $f: run ./download.sh" >&2; exit 1; }
	done
fi

random() { openssl rand -base64 32 | tr -d '/+=' | cut -c1-32; }

# --- secrets: generated once, never printed, never in git ---
umask 077
mkdir -p secrets
chmod 700 secrets
[ -f secrets/mariadb_root_password ] || random > secrets/mariadb_root_password
[ -f secrets/emerse_db_password ] || random > secrets/emerse_db_password
if [ ! -f secrets/emerse-secrets.properties ]; then
	{
		echo "# loaded by Tomcat context.xml after emerse.properties"
		echo "ds.password=$(cat secrets/emerse_db_password)"
		echo "admin.clearDemoDataSecret=$(random)"
	} > secrets/emerse-secrets.properties
fi
if [ ! -f secrets/tls.key ]; then
	echo "secrets/tls.crt: generating a self-signed certificate; replace it with one from the CHI CA for aquarius to verify" >&2
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 825 \
		-subj "/CN=$(hostname)" -keyout secrets/tls.key -out secrets/tls.crt 2>/dev/null
fi
# compose bind-mounts each file into containers running as other uids; the 0700
# directory is what keeps them private on the host
chmod 644 secrets/*
umask 022

# --- config ---
mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_DIR/chi-auth-jwks.json" ]; then
	if [ -n "${CHI_AUTH_JWKS_URL:-}" ] && curl -fsS -o "$CONFIG_DIR/chi-auth-jwks.json" "$CHI_AUTH_JWKS_URL"; then
		echo "pinned CHI Authentication key from $CHI_AUTH_JWKS_URL" >&2
	else
		echo "no $CONFIG_DIR/chi-auth-jwks.json: copy $CHI_AUTH_JWKS_URL there (escher may not reach UC)" >&2
		exit 1
	fi
fi

# --- data ---
mkdir -p "$DATA_DIR/mariadb" "$DATA_DIR/solr" "$DATA_DIR/resources" "$DATA_DIR/tomcat-logs" "$DATA_DIR/backups"

solr_home="$DATA_DIR/solr/data"
if [ -d "$solr_home/documents" ]; then
	echo "Solr: $solr_home already has cores; left as is" >&2
elif ! $demo; then
	echo "Solr: the image seeds an empty index on its first start" >&2
else
	mkdir -p "$solr_home"
	unzip -q -n -d "$solr_home" "$INDEXES_ZIP"
	# backup files that slipped into the published zip
	find "$solr_home" -name '*~' -delete
	# exactly one EMERSE plugin, this release's: an older emerse-nlp.jar's
	# NlpPartialUpdateHandler (a request handler) shadows the 7.2 update handler
	rm -f "$solr_home"/lib/emerse-nlp.jar "$solr_home"/lib/solr-plugin-*.jar
	cp "assets/solr-plugin-$EMERSE_VERSION.jar" "$solr_home/lib/"
	cp assets/solrconfig.xml "$solr_home/documents/conf/solrconfig.xml"
	echo "Solr: demo index unpacked" >&2
fi

if [ "$(id -u)" = 0 ]; then
	# compose mounts backups/solr inside SOLR_HOME; if SOLR_HOME is missing, Docker
	# creates it as root to hold that mount point and the seed can't write to it
	mkdir -p "$solr_home"
	chown -R 8983:8983 "$DATA_DIR/solr"
	mkdir -p "$DATA_DIR/backups/solr"
	chown 8983:8983 "$DATA_DIR/backups/solr"
	chown -R 1000:1000 "$DATA_DIR/resources" "$DATA_DIR/tomcat-logs"
fi

echo "ready: docker compose pull && docker compose up -d" >&2
