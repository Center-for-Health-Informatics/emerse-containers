# EMERSE 7.2.1 needs Java 25 and Tomcat 10.1 (install guide). Build context is the repo
# root (build.sh), so this can reach sso-valve/, etc/ and assets/ (fetched by download.sh).
ARG TOMCAT_TAG=10.1-jdk25-temurin

# the jar is the same on every platform: build it natively, not under emulation
FROM --platform=$BUILDPLATFORM docker.io/library/maven:3-eclipse-temurin-25 AS valve
WORKDIR /src
COPY sso-valve/pom.xml .
RUN mvn -q -B dependency:go-offline
COPY sso-valve/src src
RUN mvn -q -B package

FROM docker.io/library/tomcat:${TOMCAT_TAG}

RUN set -eux; \
	apt-get update; \
	apt-get -y --no-install-recommends install curl; \
	rm -rf /var/lib/apt/lists/*; \
	# the Ubuntu base ships an "ubuntu" user on 1000; CHI containers run as 1000
	if id ubuntu >/dev/null 2>&1; then userdel -r ubuntu; fi; \
	groupadd --gid 1000 emerse; \
	useradd --uid 1000 --gid 1000 -d /app emerse; \
	rm -rf /usr/local/tomcat/webapps/* /usr/local/tomcat/webapps.dist

COPY --from=valve /src/target/emerse-sso-valve.jar /usr/local/tomcat/lib/
COPY assets/mariadb-java-client.jar /usr/local/tomcat/lib/
COPY assets/emerse.war /opt/emerse/emerse.war
COPY etc/emerse.properties.template /opt/emerse/
COPY tomcat/conf/ /usr/local/tomcat/conf/
COPY --chmod=755 tomcat/entrypoint.sh /usr/local/bin/emerse-entrypoint

RUN set -eux; \
	cat /usr/local/tomcat/conf/catalina.properties.append >> /usr/local/tomcat/conf/catalina.properties; \
	rm /usr/local/tomcat/conf/catalina.properties.append; \
	mkdir -p /usr/local/tomcat/conf/Catalina/localhost /app/resources; \
	chown -R emerse:emerse /usr/local/tomcat/conf/Catalina /usr/local/tomcat/logs /usr/local/tomcat/temp /usr/local/tomcat/work /usr/local/tomcat/webapps /app

USER emerse
EXPOSE 8443

ENTRYPOINT ["emerse-entrypoint"]
CMD ["catalina.sh", "run"]
