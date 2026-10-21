# Local demo stack

The whole EMERSE stack on a laptop, with EMERSE's synthetic demo data (636k notes for 10k
made-up patients). A dev nginx stands in for hermes, CHI Authentication and aquarius: it
sends one fixed identity as an `SSO-Assertion`, signed by a local key. **Never load real
notes here.**

```sh
./download.sh
PLATFORMS=linux/arm64 ./build.sh   # this machine's architecture is enough here
cp .env.example .env      # then edit: see below
mkdir -p etc/local && node dev/dev-signer.mjs jwks etc/local
./deploy.sh --demo
export DEV_SSO_ASSERTION=$(node dev/dev-signer.mjs token emerse 8)   # 8 hours as "emerse"
docker compose -f compose.yaml -f dev/compose.dev.yaml up -d
open http://localhost:8088/emerse7/
```

With podman, use `podman-compose` and `COMPOSE=podman-compose bin/…`. After changing an
image, rerun `build.sh` (`IMAGES=tomcat` for one) and recreate that service.

`.env` for a laptop:

```
DATA_DIR=./data
BIND_ADDRESS=127.0.0.1
EMERSE_CONTEXT=emerse7
PUBLIC_ORIGIN=http://localhost:8088
SSO_TRUSTED_PROXIES=
CLIENT_IP_INTERNAL_PROXIES=
CLIENT_IP_TRUSTED_PROXIES=
TOMCAT_HEAP=2g
SOLR_HEAP=2g
```

`emerse` is the demo administrator (all roles). `mrnuser` and `listuser` are restricted
users. To be someone else, mint another token and recreate the proxy:

```sh
export DEV_SSO_ASSERTION=$(node dev/dev-signer.mjs token mrnuser)
docker compose -f compose.yaml -f dev/compose.dev.yaml up -d --force-recreate devproxy
```

Tomcat is also on `https://127.0.0.1:8443/emerse7/` directly, for poking at the Valve:

```sh
curl -sk https://127.0.0.1:8443/emerse7/springmvc/user-settings \
  -H "SSO-Assertion: $(node dev/dev-signer.mjs token emerse)"
```

`dev/.dev-signing-key.pem` can sign in as anyone: it is gitignored, and no real deployment
may pin its JWKS.

On `/emerse7/diagnostics.html`, every check passes except SOLR_SCHEMA. That one fails on
`RPT_TEXT` because of an upstream inconsistency (main README, "Upstream quirks"). On an
empty production index, the MRN, date and source checks also fail until notes are loaded.
That is expected.
