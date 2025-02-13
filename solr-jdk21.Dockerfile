FROM eclipse-temurin:21-jdk-noble

ARG SOLR_VERSION="9.8.0"
# empty for the full distribution, "-slim" for the slim distribution
ARG SOLR_DIST="-slim"
ARG SOLR_SHA512="ba30ce2933fee3a7e13fb71d24c78860e45d11b36197eac95c7b8aa1faa1cfbf4d1bbf32e6d43c9a660f92e33c1e063db9b12fa5bbd3b023e01bb3f1d793f299"
ARG SOLR_KEYS="EDF961FF03E647F9CA8A9C2C758051CCA3A13A7F"

# Override the default solr download location with a preferred mirror, e.g.:
#   docker build -t mine --build-arg SOLR_DOWNLOAD_SERVER=https://downloads.apache.org/solr/solr .
# This server must support downloading at: ${SOLR_DOWNLOAD_SERVER}/${SOLR_VERSION}/solr-${SOLR_VERSION}(-slim).tgz(.asc)
ARG SOLR_DOWNLOAD_SERVER="https://www.apache.org/dyn/closer.lua?action=download&filename=/solr/solr"

RUN set -ex; \
  apt-get update; \
  apt-get -y --no-install-recommends install wget gpg gnupg dirmngr; \
  rm -rf /var/lib/apt/lists/*; \
  export SOLR_BINARY="solr-$SOLR_VERSION$SOLR_DIST.tgz"; \
  MAX_REDIRECTS=3; \
  case "${SOLR_DOWNLOAD_SERVER}" in \
    (*"apache.org"*);; \
    (*) \
      # If a non-ASF URL is provided, allow more redirects and skip GPG step.
      MAX_REDIRECTS=4 && \
      SKIP_GPG_CHECK=true;; \
  esac; \
  SKIP_GPG_CHECK=true; \
  export DOWNLOAD_URL="$SOLR_DOWNLOAD_SERVER/$SOLR_VERSION/$SOLR_BINARY"; \
  echo "downloading $DOWNLOAD_URL"; \
  if ! wget -t 10 --max-redirect $MAX_REDIRECTS --retry-connrefused -nv "$DOWNLOAD_URL" -O "/opt/$SOLR_BINARY"; then rm -f "/opt/$SOLR_BINARY"; fi; \
  if [ ! -f "/opt/$SOLR_BINARY" ]; then echo "failed download attempt for $SOLR_BINARY"; exit 1; fi; \
  echo "$SOLR_SHA512 */opt/$SOLR_BINARY" | sha512sum -c -; \
  if [ -z "$SKIP_GPG_CHECK" ]; then \
    # Setup GPG \
    export GNUPGHOME="/tmp/gnupg_home"; \
    mkdir -p "$GNUPGHOME"; \
    chmod 700 "$GNUPGHOME"; \
    echo "disable-ipv6" >> "$GNUPGHOME/dirmngr.conf"; \
    if [ -n "$SOLR_KEYS" ]; then \
      # Install all Solr GPG Keys to start
      wget -nv "https://downloads.apache.org/solr/KEYS" -O- | \
        gpg --batch --import --key-origin 'url,https://downloads.apache.org/solr/KEYS'; \
      # Save just the release key
      release_keys="$(gpg --batch --export -a ${SOLR_KEYS})"; \
      rm -rf "$GNUPGHOME"/*; \
      echo "${release_keys}" | gpg --batch --import; \
    fi; \
    # Do GPG Checks
    echo "downloading $DOWNLOAD_URL.asc"; \
    wget -nv "$DOWNLOAD_URL.asc" -O "/opt/$SOLR_BINARY.asc"; \
    (>&2 ls -l "/opt/$SOLR_BINARY" "/opt/$SOLR_BINARY.asc"); \
    gpg --batch --verify "/opt/$SOLR_BINARY.asc" "/opt/$SOLR_BINARY"; \
    # Cleanup GPG
    { command -v gpgconf; gpgconf --kill all || :; }; \
    rm -r "$GNUPGHOME"; \
  else \
    echo "Skipping GPG validation due to non-Apache build"; \
  fi; \
  tar -C /opt --extract --preserve-permissions --file "/opt/$SOLR_BINARY"; \
  rm "/opt/$SOLR_BINARY"*; \
  apt-get -y remove gpg dirmngr && apt-get -y autoremove;



LABEL org.opencontainers.image.title="Apache Solr"
LABEL org.opencontainers.image.description="Apache Solr is the popular, blazing-fast, open source search platform built on Apache Lucene."
LABEL org.opencontainers.image.authors="The Apache Solr Project"
LABEL org.opencontainers.image.url="https://solr.apache.org"
LABEL org.opencontainers.image.source="https://github.com/apache/solr"
LABEL org.opencontainers.image.documentation="https://solr.apache.org/guide/"
LABEL org.opencontainers.image.version="${SOLR_VERSION}"
LABEL org.opencontainers.image.licenses="Apache-2.0"

ENV SOLR_USER="solr" \
    SOLR_UID="8983" \
    SOLR_GROUP="solr" \
    SOLR_GID="8983" \
    PATH="/opt/solr/bin:/opt/solr/docker/scripts:/opt/solr/prometheus-exporter/bin:$PATH" \
    SOLR_INCLUDE=/etc/default/solr.in.sh \
    SOLR_HOME=/var/solr/data \
    SOLR_PID_DIR=/var/solr \
    SOLR_LOGS_DIR=/var/solr/logs \
    LOG4J_PROPS=/var/solr/log4j2.xml \
    SOLR_JETTY_HOST="0.0.0.0" \
    SOLR_ZK_EMBEDDED_HOST="0.0.0.0"

RUN set -ex; \
  groupadd -r --gid "$SOLR_GID" "$SOLR_GROUP"; \
  useradd -r --uid "$SOLR_UID" --gid "$SOLR_GID" "$SOLR_USER"

# add symlink to /opt/solr, remove what we don't want.
# Remove the Dockerfile because it might not represent the dockerfile that was used to generate the image.
RUN set -ex; \
  (cd /opt; ln -s solr-*/ solr); \
  rm -Rf /opt/solr/docs /opt/solr/docker/Dockerfile;

RUN set -ex; \
  mkdir -p /opt/solr/server/solr/lib /docker-entrypoint-initdb.d; \
  cp /opt/solr/bin/solr.in.sh /etc/default/solr.in.sh; \
  mv /opt/solr/bin/solr.in.sh /opt/solr/bin/solr.in.sh.orig; \
  mv /opt/solr/bin/solr.in.cmd /opt/solr/bin/solr.in.cmd.orig; \
  chmod 0664 /etc/default/solr.in.sh; \
  mkdir -p -m0770 /var/solr; \
  chown -R "$SOLR_USER:0" /var/solr; \
  test ! -e /opt/solr/modules || ln -s /opt/solr/modules /opt/solr/contrib; \
  test ! -e /opt/solr/prometheus-exporter || ln -s /opt/solr/prometheus-exporter /opt/solr/modules/prometheus-exporter;

RUN set -ex; \
    apt-get update; \
    apt-get -y --no-install-recommends install acl lsof procps wget gosu tini jattach; \
    rm -rf /var/lib/apt/lists/*;

VOLUME /var/solr
EXPOSE 8983
WORKDIR /opt/solr
USER $SOLR_UID

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["solr-foreground"]
