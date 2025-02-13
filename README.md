# emerse-containers
Emerse 7 in Containers

* [Installation Guide](https://project-emerse.org/documentation/install_guide.html)

## External Resources

* [JDBC database driver for MariaDB](https://dlm.mariadb.com/4174416/Connectors/java/connector-java-3.5.2/mariadb-java-client-3.5.2.jar)
* [Assets for Emerse v7.0.0](https://github.com/project-emerse/emerse/releases/tag/v7.0.0)
  * [database initialization](https://github.com/project-emerse/emerse/releases/download/v7.0.0/fresh-install-7.0.0.mariadb.sql)
  * [emerse.properties template](https://github.com/project-emerse/emerse/releases/download/v7.0.0/emerse.properties)
  * [EMERSE WAR file](https://github.com/project-emerse/emerse/releases/download/v7.0.0/emerse.war)
* [Solr Indexes for Emerse 7](https://project-emerse.org/repo/org/emerse/solr-indexes/7.0.0/solr-indexes-7.0.0.zip)

## Base Images

* [MariaDB Server](https://hub.docker.com/_/mariadb) (`mariadb:latest`)
* [Apache Tomcat](https://hub.docker.com/_/tomcat) (`tomcat:10`)
* [Apache Solr](https://hub.docker.com/_/solr) (*The official build of `solr:9.8-slim` uses a version 17 JDK, but we need version 21, so we build a custom image with a modified version of the official Dockerfile.*)

## Scripts

### `download.sh`

Pull all of the required assets — requires the [GitHub command-line tool](https://cli.github.com) — and puts them in the `$ASSETS` directory.

### `deploy.sh`

* Unzip the Emerse Solr indexes from the `$ASSETS` directory into the `$SOLR_HOME` directory.
* Modify the default `emerse.properties` file with local values. (The `${VAR}` syntax does not seem to work in the Emerse project.)

## Environment

| name | value |
|------|-------|
| TZ | server timezone |
| EMERSE_DB_PASSWORD | for the MariaDB Emerse database |
| EMERSE_HOME | local folder to mount as the Emerse home in Tomcat |
| ASSETS | local folder to hold downloaded assets |
| SOLR_HOME | local folder to mount in Solr with index files |
| MARIADB_ROOT_PASSWORD | needed to run the healthcheck |
