#!/bin/sh

if [ -n "$ASSETS" ]; then
  mkdir -p "$ASSETS"

  gh release download v7.0.0 --repo project-emerse/emerse --pattern "emerse.properties" --dir "$ASSETS" --skip-existing
  gh release download v7.0.0 --repo project-emerse/emerse --pattern "emerse.war" --dir "$ASSETS" --skip-existing
  gh release download v7.0.0 --repo project-emerse/emerse --pattern "fresh-install-7.0.0.mariadb.sql" --dir "$ASSETS" --skip-existing
  wget --output-document="$ASSETS/mariadb-java-client-3.5.2.jar" --no-clobber https://dlm.mariadb.com/4174416/Connectors/java/connector-java-3.5.2/mariadb-java-client-3.5.2.jar
  wget --output-document="$ASSETS/solr-indexes-7.0.0.zip" --no-clobber https://project-emerse.org/repo/org/emerse/solr-indexes/7.0.0/solr-indexes-7.0.0.zip
else
  echo "ASSETS is not set or empty"
fi
