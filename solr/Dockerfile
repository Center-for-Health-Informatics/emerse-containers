# The official solr image runs Java 17, but the EMERSE Solr plugins (solr-plugin-*.jar,
# emerse-nlp.jar) are compiled for Java 21 (class file 65). Lift Solr out of the official
# image onto a Java 21 runtime instead of rebuilding it from the Apache tarball. Build
# context is the repo root (build.sh), for assets/ (fetched by download.sh).
ARG SOLR_VERSION=9.9.0

FROM docker.io/library/solr:${SOLR_VERSION} AS solr

# EMERSE's Solr home from solr-indexes-7.2.0.zip, minus its demo data (download.sh), with
# exactly one EMERSE plugin, this release's: an older emerse-nlp.jar's
# NlpPartialUpdateHandler (a request handler) shadows the 7.2 update handler
FROM --platform=$BUILDPLATFORM docker.io/library/solr:${SOLR_VERSION} AS home
ARG EMERSE_VERSION
USER root
COPY assets/solr-home /solr-home
COPY assets/solr-plugin-${EMERSE_VERSION}.jar assets/solrconfig.xml /tmp/
RUN set -eux; \
	# backup files that slipped into the published zip
	find /solr-home -name '*~' -delete; \
	rm -f /solr-home/lib/emerse-nlp.jar /solr-home/lib/solr-plugin-*.jar; \
	cp /tmp/solr-plugin-${EMERSE_VERSION}.jar /solr-home/lib/; \
	cp /tmp/solrconfig.xml /solr-home/documents/conf/solrconfig.xml

FROM docker.io/library/eclipse-temurin:21-jre-noble
ARG SOLR_VERSION

RUN set -eux; \
	apt-get update; \
	apt-get -y --no-install-recommends install lsof procps curl jattach tini; \
	rm -rf /var/lib/apt/lists/*; \
	groupadd -r --gid 8983 solr; \
	useradd -r --uid 8983 --gid 8983 solr

COPY --from=solr /opt/solr-${SOLR_VERSION} /opt/solr-${SOLR_VERSION}
COPY --from=solr /etc/default/solr.in.sh /etc/default/solr.in.sh
COPY --from=solr --chown=solr:0 /var/solr /var/solr
COPY --from=home --chown=solr:0 /solr-home /opt/emerse/solr-home

# the official entrypoint scripts expect tini (above) and this directory
RUN ln -s /opt/solr-${SOLR_VERSION} /opt/solr && mkdir /docker-entrypoint-initdb.d
COPY solr/seed-solr-home.sh /docker-entrypoint-initdb.d/10-emerse-solr-home.sh

# the same environment the official image sets
ENV SOLR_USER=solr \
	SOLR_UID=8983 \
	SOLR_GROUP=solr \
	SOLR_GID=8983 \
	PATH="/opt/solr/bin:/opt/solr/docker/scripts:/opt/solr/prometheus-exporter/bin:$PATH" \
	SOLR_INCLUDE=/etc/default/solr.in.sh \
	SOLR_HOME=/var/solr/data \
	SOLR_PID_DIR=/var/solr \
	SOLR_LOGS_DIR=/var/solr/logs \
	LOG4J_PROPS=/var/solr/log4j2.xml \
	SOLR_JETTY_HOST=0.0.0.0 \
	SOLR_ZK_EMBEDDED_HOST=0.0.0.0 \
	# EMERSE's install guide starts Solr this way; the NLP plugin needs it
	SOLR_SECURITY_MANAGER_ENABLED=false

VOLUME /var/solr
EXPOSE 8983
WORKDIR /opt/solr
USER 8983

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["solr-foreground"]
