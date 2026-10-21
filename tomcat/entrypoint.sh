#!/bin/sh
set -eu

# Mount the one WAR at /$EMERSE_CONTEXT: "emerse7" while v6 still owns /emerse, then
# "emerse" at cutover. A context file named for the path, outside appBase, is how
# Tomcat does that without renaming the WAR.
context="${EMERSE_CONTEXT:-emerse}"
case "$context" in
	*[!A-Za-z0-9_-]*|'') echo "EMERSE_CONTEXT must be a plain path segment, got '$context'" >&2; exit 1 ;;
esac
rm -f /usr/local/tomcat/conf/Catalina/localhost/*.xml
cat > "/usr/local/tomcat/conf/Catalina/localhost/$context.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<Context docBase="/opt/emerse/emerse.war"/>
EOF

# EMERSE settings: the image's template with PUBLIC_ORIGIN (from .env) filled in
case "${PUBLIC_ORIGIN:-}" in
	http://*|https://*) ;;
	*) echo "PUBLIC_ORIGIN must be an http(s) origin, got '${PUBLIC_ORIGIN:-}'" >&2; exit 1 ;;
esac
case "$PUBLIC_ORIGIN" in
	*[!A-Za-z0-9.:/-]*) echo "PUBLIC_ORIGIN has unexpected characters: '$PUBLIC_ORIGIN'" >&2; exit 1 ;;
esac
sed "s|@PUBLIC_ORIGIN@|$PUBLIC_ORIGIN|g" /opt/emerse/emerse.properties.template > /app/emerse.properties

for f in /app/etc/chi-auth-jwks.json /run/secrets/emerse-secrets.properties /run/secrets/tls.crt /run/secrets/tls.key; do
	[ -r "$f" ] || { echo "missing $f (see README: deploy.sh)" >&2; exit 1; }
done

export CATALINA_OPTS="${CATALINA_OPTS:-} -Xms${TOMCAT_HEAP:-2g} -Xmx${TOMCAT_HEAP:-2g} -Demerse.properties.filepath=/app/emerse.properties"
exec "$@"
