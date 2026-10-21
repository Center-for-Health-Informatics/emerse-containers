# EMERSE 7 at CHI

EMERSE 7.2.1 (clinical notes search) for UC researchers. It replaces the v6.3.3 instance
on chi-emerse. **Every container here can hold PHI** and runs only at UC Health, on
chi-escher. UC users reach it through CHI's proxies, signed in by CHI Authentication.

## Request path

```
browser (UC network / VPN)
  └─ chi-hermes  https://chi-tools.uc.edu/emerse7/       UC
       ├─ auth_request → CHI Authentication (chi-cetus)   is this person listed on EMERSE?
       │                 200 + SSO-Assertion (ES256 JWT, 2 min)
       └─ proxy → https://asclepius.uchealth.com/emerse7/
            └─ chi-aquarius (172.31.246.247)              UC Health
                 └─ proxy → https://10.52.31.13:8443/emerse7/
                      └─ chi-escher: tomcat ─┬─ database (MariaDB)   internal network only
                                             └─ solr                 internal network only
```

The proxy configs are in `Infrastructure/UC/hermes/nginx/snippets/emerse-v7.conf` and
`Infrastructure/UCHealth/chi-aquarius/etc/nginx/snippets/emerse7.conf`. Solr is not
proxied anywhere: the index holds every note.

**Who gets in** is decided twice:
1. **CHI Authentication.** The "EMERSE" resource on chi-tools.uc.edu has every "anyone
   who signs in with…" box unticked, so only listed people pass. Each listing has a last
   day (CITI and IRB expiry) and a note. **Expiring access** in its admin shows what needs
   renewing.
2. **EMERSE.** The username must have an active `LOGIN_ACCOUNT`. Roles (ADMIN,
   EMERSE_FULL, …) live there.

**How identity reaches EMERSE.** `sso-valve/` is a Tomcat Valve. It runs before anything
else and does the following:
- Verifies the `SSO-Assertion`: ES256 signature against the pinned CHI key, plus `iss`,
  `aud` and `exp`.
- Accepts it only from aquarius.
- Sets the request's remote user. EMERSE's `preauth` profile reads that remote user
  (`LoginService`, with `preauth.header` unset).
- Strips `Authorization`, because EMERSE still honours HTTP Basic against
  `LOGIN_ACCOUNT` passwords.
- Expires a session if it was started for someone else, or if a request arrives with no
  assertion.

The plain `SSO-Username` header is ignored.

## Layout

| Path | What |
|---|---|
| `compose.yaml` | database (mariadb:11.4), solr (9.9 on Java 21), tomcat (10.1, Java 25), all from `chi-tools.uc.edu` |
| `tomcat/` | image: Tomcat with the WAR, MariaDB driver, Valve; TLS-only `server.xml` |
| `solr/` | image: the official Solr 9.9 lifted onto Java 21 (the EMERSE plugins need 21), plus an empty EMERSE Solr home it seeds on first start |
| `sso-valve/` | the Valve, with tests (one verifies a token minted by CHI Authentication itself) |
| `etc/emerse.properties.template` | EMERSE settings; baked into the tomcat image, which fills in `PUBLIC_ORIGIN` |
| `database/` | image: MariaDB settings (utf8mb4_bin), the fresh install, and the lock-down run after it |
| `bin/emerse-user.sh` | create an EMERSE account for a CHI username, with roles |
| `bin/backup.sh` | nightly MariaDB dump and Solr snapshots |
| `download.sh`, `build.sh` | dev machine: fetch release artifacts; build and push the images |
| `deploy.sh` | prepare a host: secrets, the pinned CHI key, data directories |
| `dev/` | a laptop stack with a stand-in for hermes, aquarius and CHI Authentication |

`assets/`, `secrets/`, `etc/local/`, `data/` and `.env` are not in git.

## Building the images

On a dev machine with podman and `gh` signed in with access to `project-emerse/emerse`.
Nothing that needs GitHub runs on escher.

1. `./download.sh` fetches about 3.1 GB, including the 7.2.0 Solr home, and unpacks that
   home without its demo data into `assets/solr-home/`.
2. `./build.sh` builds `chi-tools.uc.edu/emerse-database`, `emerse-solr` and
   `emerse-tomcat` for amd64 and arm64.
3. Commit, then `PUSH=1 ./build.sh`. It pushes `7.2.1`, `7.2.1-g<sha>` and `latest`, and
   refuses a dirty tree. Requires a one-time `podman login chi-tools.uc.edu`.

The images hold EMERSE's licensed release files (WAR, schema, Solr plugin) but no PHI and
no secrets.

## Deploying on chi-escher

Needs Docker with Compose v2, and about 32 GB RAM and 8 CPUs for the full index. Escher
needs only four things from this repo, about 20 KB, with no checkout:

```sh
tar czf - compose.yaml .env.example deploy.sh bin | ssh chi-escher 'mkdir -p ~/emerse7 && tar xzf - -C ~/emerse7'
```

1. `docker login chi-tools.uc.edu` once.
2. `cp .env.example .env` and check every value. `DATA_DIR` goes on the 1 TB disk.
3. Put CHI Authentication's public key at `etc/local/chi-auth-jwks.json`. `deploy.sh`
   fetches it if escher can reach UC; otherwise copy
   `https://chi-tools.uc.edu/auth/.well-known/jwks.json` across by hand. Re-copy it
   whenever CHI Authentication's `SSO_SIGNING_KEY` changes. Until then every request is
   refused with a 403, which is the safe failure.
4. `sudo ./deploy.sh` creates `secrets/` (random passwords, the EMERSE secrets file and a
   self-signed TLS certificate) and the data directories.
   - For aquarius to verify the TLS hop, replace `secrets/tls.crt` and `secrets/tls.key`
     with a certificate from the CHI CA, then turn `proxy_ssl_verify` on in aquarius's
     snippet.
5. `docker compose pull && docker compose up -d`.
   - On the first start MariaDB runs the fresh install, then `90-chi-lockdown.sql`, and
     Solr seeds an empty EMERSE home into `$DATA_DIR/solr`.
   - **If that first start fails partway, the volume is left half-built and later starts
     look healthy.** Stop the stack, empty `$DATA_DIR/mariadb`, and start again.
6. `bin/emerse-user.sh <your-6+2> <First> <Last> ADMIN EMERSE_FULL` creates the first
   administrator. Add everyone else in EMERSE's admin app, or with the same script.
7. In CHI Authentication, create the **EMERSE** resource:
   - domain chi-tools.uc.edu; URI roots `/emerse7/` (and later `/emerse/`);
   - no sign-in sources ticked;
   - list the approved people, each with a last day and a note.
8. Push the hermes and aquarius snippets and reload nginx on each. Then sign in at
   `https://chi-tools.uc.edu/emerse7/` and open `/emerse7/diagnostics.html`.
9. Schedule `bin/backup.sh` (cron, nightly), and copy `$DATA_DIR/backups` to UC Health
   storage.

**Updating.** Push new images from the dev machine, then on escher run `docker compose
pull && docker compose up -d`. To roll back, set `TAG=7.2.1-g<sha>` in `.env` and run the
same command. A new image never touches an existing database or Solr home: the fresh
install and the Solr seed run only against empty directories.

## Network exposure

Tomcat accepts an assertion only from `SSO_TRUSTED_PROXIES`, and the assertion is signed.
Even so, the published port must be reachable from aquarius alone.

**Docker-published ports bypass ufw**: Docker's own iptables rules accept the traffic
before ufw's INPUT chain sees it. Restrict the port in the `DOCKER-USER` chain:

```sh
iptables -I DOCKER-USER -p tcp --dport 8443 ! -s 172.31.246.247 -j DROP
```

Then check from somewhere else on UC Health's and UC's 10.x networks; it should time out:

```sh
nc -vz 10.52.31.13 8443
```

Note that 10.0.0.0/8 includes UC Health hosts as well as UC ones. The database and Solr
publish nothing, and their network is `internal` (no route out).

## Accounts

The fresh install ships four app accounts with well-known passwords: `emerse`/`demouser`,
`mrnuser`, `listuser` and the aggregate user. `database/initdb/90-chi-lockdown.sql` sets
every `LOGIN_ACCOUNT` to external auth with no usable password. With no LDAP profile and
the Valve stripping `Authorization`, the only way in is a CHI assertion. Nobody signs in to
CHI as `emerse`, so those accounts are inert. Deactivate them in the admin app once real
accounts exist.

EMERSE usernames must match CHI's `SSO-Username` exactly, case included: a UC 6+2, or an
email address for Children's and email-link accounts.

## Upstream quirks found while building this

- The 7.2.1 release publishes only the WAR, SQL, `solr-plugin-7.2.1.jar` and
  `solrconfig.xml`. The Solr home (cores, NLP models, dictionaries) comes from
  `solr-indexes-7.2.0.zip`, the bundle upstream's desktop launcher uses.
  - Its data is synthetic demo data. `download.sh` leaves it out of the image's copy;
    only `deploy.sh --demo` unpacks it.
  - **Known diagnostic failure.** Every 7.2 Solr home upstream publishes types `RPT_TEXT`
    as `text_with_header_hybrid` (HybridTokenizerFactory, with the ewt sentence model).
    That covers this bundle, `indexes-empty.zip` and the desktop launcher's. But the
    reference schema built into the 7.2.1 WAR
    (`modules/org.emerse.search.solr/.../managed-schema`) still expects
    `text_with_header_post_analysis` with `sd-med-model.zip`.
    - So `/emerse7/diagnostics.html` reports **SOLR_SCHEMA ERRORED** for `RPT_TEXT`. Every
      other check passes, and so do NLP searches.
    - We keep the shipped bundle rather than mixing in 7.0 files. Ask the EMERSE team which
      is intended **before the full re-index**, because the field type decides how notes
      are analysed.
- Keep exactly one EMERSE jar in Solr's `lib/`. An older `emerse-nlp.jar` defines
  `NlpPartialUpdateHandler` as a request handler and shadows the 7.2 update handler
  (ClassCastException at core load).
- The official `solr` image runs Java 17; the EMERSE plugins are class-file 65 (Java 21).
- EMERSE's `solr.xml` has no `allowPaths`, so snapshots go inside `SOLR_HOME`
  (`/var/solr/data/backups`).
- MariaDB on a case-insensitive filesystem (a macOS bind mount) falls back to
  `lower_case_table_names=2`, and the fresh install fails. Linux is fine; `dev/` uses a
  named volume.

## Loading notes

Not part of this first build. The v6 loader
(`legacy/v6Emerse/emerse_admin/.../load_valid_json_with_source.py`) needs rewriting for
7.x:
- prepend the NLP header and compute `AGE_DAYS` and `AGE_MONTHS`;
- upsert `PATIENT` rows in MariaDB, so a null DOB no longer fails a whole file;
- post to Solr 9.

Build it against synthetic fixtures first. Real exports (`../data-PHI/`) are loaded only
on escher.

## Cutover from v6

1. Load the full index and check counts against v6: about 790k patients, 49M notes.
2. Set `EMERSE_CONTEXT=emerse` in `.env` and give CHI's EMERSE resource the URI root
   `/emerse/`, then recreate tomcat (`docker compose up -d tomcat`).
3. Point hermes's `/emerse/` (and aquarius's) at escher.
   - Drop the v6 `/solr/`, `/emerse_admin/` and `/emerse_admin_static/` locations. v6
     exposes Solr through hermes today.
   - Redirect `chi.uc.edu/emerse/` to chi-tools: assertions are per-vhost.
4. Update `enter_emerse` and the SOP.
5. Export the v6 SQL Server database (`emerse_tst`) as the archive of v6 users, searches
   and audit logs.
6. Retire chi-emerse and chi-aries.
