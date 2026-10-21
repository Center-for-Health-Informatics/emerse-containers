#!/bin/sh
# Fetch the release artifacts the images (build.sh) and deploy.sh --demo need into
# ./assets. Needs `gh` signed in with access to project-emerse/emerse (private), so it runs
# on a dev machine, never on escher.
set -eu
cd "$(dirname "$0")"

EMERSE_VERSION=7.2.1
# the newest published Solr home: cores, NLP models and dictionaries, plus synthetic demo
# data. Production starts from it with the data removed, as upstream's upgrading guide says.
INDEXES_VERSION=7.2.0
MARIADB_JDBC_VERSION=3.5.10

mkdir -p assets
gh release download "v$EMERSE_VERSION" --repo project-emerse/emerse --dir assets --skip-existing \
	--pattern emerse.war \
	--pattern "fresh-install-v$EMERSE_VERSION.maria.sql" \
	--pattern "solr-plugin-$EMERSE_VERSION.jar" \
	--pattern solrconfig.xml

# 3 GB; the URL is the one upstream's desktop launcher uses (DesktopSolr.java)
if [ ! -f "assets/solr-indexes-$INDEXES_VERSION.zip" ]; then
	curl -fL --retry 3 -o "assets/solr-indexes-$INDEXES_VERSION.zip.part" \
		"https://project-emerse.org/repo/org/emerse/solr-indexes/$INDEXES_VERSION/solr-indexes-$INDEXES_VERSION.zip"
	mv "assets/solr-indexes-$INDEXES_VERSION.zip.part" "assets/solr-indexes-$INDEXES_VERSION.zip"
fi

# the Solr home without its demo data, for the solr image; the upgrading guide starts
# production from the demo cores with their data removed
if [ ! -d assets/solr-home ]; then
	rm -rf assets/solr-home.part
	unzip -q -d assets/solr-home.part "assets/solr-indexes-$INDEXES_VERSION.zip" -x 'documents/data/*' 'patient/data/*'
	mv assets/solr-home.part assets/solr-home
fi

if [ ! -f assets/mariadb-java-client.jar ]; then
	base="https://repo1.maven.org/maven2/org/mariadb/jdbc/mariadb-java-client/$MARIADB_JDBC_VERSION/mariadb-java-client-$MARIADB_JDBC_VERSION.jar"
	curl -fL --retry 3 -o assets/mariadb-java-client.jar.part "$base"
	expected=$(curl -fsSL "$base.sha1")
	actual=$(shasum -a 1 assets/mariadb-java-client.jar.part | cut -d' ' -f1)
	[ "$expected" = "$actual" ] || { echo "mariadb-java-client checksum mismatch" >&2; rm assets/mariadb-java-client.jar.part; exit 1; }
	mv assets/mariadb-java-client.jar.part assets/mariadb-java-client.jar
fi

ls -l assets
