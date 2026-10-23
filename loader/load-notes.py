#!/usr/bin/env python3
# Load Epic note exports into EMERSE 7: patients into MariaDB (PATIENT) and the Solr
# patient core, notes into the Solr documents core. Replaces v6's load_valid_json_with_source.
#
# Each export is a JSON array of notes, one file per note type and week, named
# <type>_<YYYY_MM_DD>_<YYYY_MM_DD>.json. Files load oldest week first, and within a run
# only the latest version of each NoteID is kept (by NoteDate, then NoteCSN), so a newer
# export overwrites an older one. Loading a file again is harmless: patients are matched
# on MRN and notes on NoteID.
#
# Prints counts and file names only. Solr's error bodies can quote note fields, so they go
# to $STATE_DIR/errors/, which, like everything here, is PHI.
#
#   docker compose run --rm loader                   # every export not yet in the ledger
#   docker compose run --rm loader --force NAME...   # these exports, even if loaded before
#   docker compose run --rm loader --dry-run         # parse and count; write nothing
import argparse
import datetime as dt
import html
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

import pymysql

# NoteSource -> DOCUMENT_SOURCE.SOURCE_KEY. source5 is relabelled Cardiology by
# database/initdb/91-chi-sources.sql.
SOURCES = {
    'Main EHR': 'source1',
    'Pathology': 'source2',
    'Radiology': 'source3',
    'Other': 'source4',
    'Cardiology': 'source5',
}
SEXES = {'Female': 'F', 'Male': 'M'}

# The NLP header EMERSE's own importer and diagnostics put before RPT_TEXT; the Solr
# plugin's DocumentPartitioner reads it to align its analysis with the stored text.
NLP_HEADER = 'RU1FUlNFX0g=1|5|\n'

EXPORT_NAME = re.compile(r'_(\d{4}_\d{2}_\d{2})_(\d{4}_\d{2}_\d{2})\.json$')
REQUIRED = ('NoteID', 'MRN', 'NoteType', 'NoteSource', 'EncounterDate', 'NoteText')


def log(*args):
    print(*args, flush=True)


def note_html(text):
    # Epic's line breaks arrive as runs of four spaces. Escape first: the indexer strips
    # HTML, and a bare "<" in "<5 mg" would otherwise hide the text after it.
    text = html.escape(text, quote=False)
    text = text.replace('    ', '<br>')
    text = re.sub(r'<br>\s*', '<br>', text)
    text = re.sub(r'<br><br>(<br>)*', '<br><br>', text)
    return text.replace('•', '<br>  •')


def parse_ts(value):
    # exports carry local wall-clock times; EMERSE renders dates in UTC, so like v6 they
    # are stored as if UTC and display unchanged
    return dt.datetime.fromisoformat(value)


def solr_ts(t):
    return t.strftime('%Y-%m-%dT%H:%M:%SZ')


def age(birth, on):
    days = (on - birth).days
    months = (on.year - birth.year) * 12 + on.month - birth.month
    if on.day < birth.day:
        months -= 1
    return days, months


def version_key(note):
    try:
        csn = float(note['NoteCSN'])
    except (KeyError, TypeError, ValueError):
        csn = 0.0
    return (note.get('NoteDate') or '', csn)


def export_order(name):
    m = EXPORT_NAME.search(name)
    return (m.group(2), m.group(1), name) if m else ('', '', name)


class Solr:
    def __init__(self, url, error_dir):
        self.url = url.rstrip('/')
        self.error_dir = error_dir

    def post(self, core, payload, params='', attempts=5):
        body = json.dumps(payload, ensure_ascii=False).encode()
        req = urllib.request.Request(f'{self.url}/{core}/update{params}', data=body,
                                     headers={'Content-Type': 'application/json'})
        for attempt in range(1, attempts + 1):
            try:
                with urllib.request.urlopen(req, timeout=600) as r:
                    r.read()
                return
            except urllib.error.HTTPError as e:
                path = self.save_error(core, e.read())
                if e.code < 500 or attempt == attempts:
                    raise RuntimeError(f'Solr {core} returned HTTP {e.code}; details in {path}') from None
            except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
                if attempt == attempts:
                    raise RuntimeError(f'Solr {core} unreachable: {type(e).__name__}') from None
            log(f'  Solr {core}: attempt {attempt} failed; retrying in {30 * attempt}s')
            time.sleep(30 * attempt)

    def save_error(self, core, body):
        os.makedirs(self.error_dir, exist_ok=True)
        path = os.path.join(self.error_dir, f'{dt.datetime.now():%Y%m%d-%H%M%S-%f}-{core}.txt')
        with open(path, 'wb') as f:
            f.write(body)
        return path

    def commit(self, core):
        self.post(core, {'commit': {}})


class Patients:
    # MRN -> (ID, row) for every patient, so a run touches only new or changed ones
    COLUMNS = ('FIRST_NAME', 'LAST_NAME', 'BIRTH_DATE', 'SEX_CD', 'RACE_CD', 'ETHNICITY_CD', 'DECEASED_FLAG')

    def __init__(self, db):
        self.db = db
        self.known = {}
        self.next_id = self.end_id = 0
        with db.cursor() as c:
            c.execute(f'select EXTERNAL_ID, ID, {", ".join(self.COLUMNS)} from PATIENT')
            for mrn, pid, *row in c:
                row[-1] = bool(row[-1])
                self.known[mrn] = (pid, tuple(row))

    def allocate(self, c):
        # PATIENT_SEQ hands out blocks of 50 (increment by 50), as EMERSE's own code uses it
        if self.next_id == self.end_id:
            c.execute('select nextval(PATIENT_SEQ)')
            self.next_id = c.fetchone()[0]
            self.end_id = self.next_id + 50
        self.next_id += 1
        return self.next_id - 1

    def upsert(self, rows, solr):
        """rows: MRN -> row tuple. Commits only once Solr has the inserted or changed
        patients, so a failure leaves neither store ahead: the next run sees them as new
        again. Solr may keep docs for IDs rolled back mid-way; System → Synchronization
        (README, "Loading notes") removes them."""
        inserts, updates, docs, changed = [], [], [], {}
        now = dt.datetime.now().replace(microsecond=0)
        with self.db.cursor() as c:
            for mrn, row in rows.items():
                old = self.known.get(mrn)
                if old and old[1] == row:
                    continue
                if old:
                    pid = old[0]
                    updates.append((*row, now, pid))
                else:
                    pid = self.allocate(c)
                    inserts.append((pid, mrn, *row, now, now))
                changed[mrn] = (pid, row)
                docs.append(self.solr_doc(pid, mrn, row))
            if inserts:
                c.executemany(
                    f'insert into PATIENT (ID, EXTERNAL_ID, {", ".join(self.COLUMNS)}, CREATE_DATE, UPDATE_DATE,'
                    " DELETED_FLAG, CREATED_BY, UPDATED_BY) values (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,"
                    " false, 'chi-loader', 'chi-loader')", inserts)
            if updates:
                c.executemany(
                    f'update PATIENT set {", ".join(f"{col} = %s" for col in self.COLUMNS)}, UPDATE_DATE = %s,'
                    " DELETED_FLAG = false, UPDATED_BY = 'chi-loader' where ID = %s", updates)
        for i in range(0, len(docs), 1000):
            solr.post('patient', docs[i:i + 1000])
        self.db.commit()
        self.known.update(changed)
        return len(inserts), len(updates)

    @staticmethod
    def solr_doc(pid, mrn, row):
        first, last, birth, sex, race, ethnicity, deceased = row
        doc = {'ID': str(pid), 'MRN': mrn, 'FIRSTNAME': first, 'LASTNAME': last,
               'SEX_CD': sex, 'RACE_CD': race, 'ETHNICITY_CD': ethnicity,
               'DECEASED_FLAG': deceased, 'DELETED_FLAG': False}
        if birth:
            doc['BIRTHDATE'] = birth.strftime('%Y-%m-%dT00:00:00Z')
        return doc

    def birth_date(self, mrn):
        return self.known[mrn][1][2]


def patient_row(note):
    birth = note.get('DOB')
    return (
        (note.get('FirstName') or '')[:65] or None,
        (note.get('LastName') or '')[:75] or None,
        parse_ts(birth).date() if birth else None,
        SEXES.get(note.get('Gender'), 'U'),
        (note.get('Race') or 'Unknown')[:50],
        (note.get('Ethnicity') or 'Unknown')[:50],
        bool(note.get('DOD')),
    )


def note_doc(note, birth, missing_age, now):
    encounter = parse_ts(note['EncounterDate'])
    doc = {
        'ID': str(note['NoteID']),
        'RPT_ID': str(note['NoteID']),
        'MRN': str(note['MRN']),
        'DOC_TYPE': note['NoteType'],
        'SOURCE': SOURCES[note['NoteSource']],
        'ENCOUNTER_DATE': solr_ts(encounter),
        'ADMIT_DATE': solr_ts(encounter),
        'LAST_UPDATED': now,
        'INDEX_DATE': now,
        'NLP_HEADER': NLP_HEADER,
        'RPT_TEXT': NLP_HEADER + note_html(note['NoteText']),
    }
    if note.get('NoteDate'):
        doc['RPT_DATE'] = solr_ts(parse_ts(note['NoteDate']))
    if note.get('EncounterCSN'):
        doc['CSN'] = re.sub(r'\.0$', '', str(note['EncounterCSN']))
    for field, key in (('DEPT', 'Department'), ('CLINICIAN', 'Provider')):
        if note.get(key):
            doc[field] = note[key]
    if birth:
        doc['AGE_DAYS'], doc['AGE_MONTHS'] = age(birth, encounter.date())
    else:
        doc['AGE_DAYS'] = doc['AGE_MONTHS'] = missing_age
    return doc


def problem(note):
    """Why a note can't be loaded, without quoting it; None if it can."""
    for key in REQUIRED:
        if note.get(key) in (None, ''):
            return f'missing {key}'
    if note['NoteSource'] not in SOURCES:
        return 'unknown NoteSource'
    try:
        parse_ts(note['EncounterDate'])
        if note.get('DOB'):
            parse_ts(note['DOB'])
        if note.get('NoteDate'):
            parse_ts(note['NoteDate'])
    except (TypeError, ValueError):
        return 'unparseable date'
    return None


def batches(docs, max_docs, max_bytes):
    batch, size = [], 0
    for doc in docs:
        n = len(doc['RPT_TEXT']) + 500
        if batch and (len(batch) >= max_docs or size + n > max_bytes):
            yield batch
            batch, size = [], 0
        batch.append(doc)
        size += n
    if batch:
        yield batch


def load_file(path, args, solr, patients, pool):
    with open(path, encoding='utf-8') as f:
        notes = json.load(f)
    skipped = {}
    latest = {}
    for note in notes:
        why = problem(note)
        if why:
            skipped[why] = skipped.get(why, 0) + 1
            continue
        nid = str(note['NoteID'])
        if nid not in latest or version_key(note) >= version_key(latest[nid]):
            latest[nid] = note
    rows = {}
    for note in sorted(latest.values(), key=version_key):
        rows[str(note['MRN'])] = patient_row(note)
    stats = {'notes': len(notes), 'kept': len(latest), 'versions': len(notes) - len(latest) - sum(skipped.values()),
             'patients': len(rows), 'new': 0, 'changed': 0, 'skipped': skipped}
    if args.dry_run:
        return stats

    stats['new'], stats['changed'] = patients.upsert(rows, solr)

    now = solr_ts(dt.datetime.now(dt.timezone.utc))
    docs = (note_doc(n, patients.birth_date(str(n['MRN'])), args.missing_age, now) for n in latest.values())
    pending = []
    for b in batches(docs, args.batch_docs, args.batch_mb << 20):
        # keep a few batches queued per thread, not a whole 600 MB export
        if len(pending) >= 2 * args.threads:
            pending.pop(0).result()
        pending.append(pool.submit(solr.post, 'documents', b))
    for f in pending:
        f.result()
    return stats


def read_ledger(path):
    if not os.path.exists(path):
        return set()
    with open(path) as f:
        return {line.split('\t', 1)[0] for line in f if line.strip()}


def main():
    p = argparse.ArgumentParser()
    p.add_argument('names', nargs='*', help='export file names (default: every *.json in --exports)')
    p.add_argument('--exports', default=os.environ.get('EXPORTS', '/exports'))
    p.add_argument('--state', default=os.environ.get('STATE_DIR', '/state'), help='ledger and Solr error bodies')
    p.add_argument('--solr', default=os.environ.get('SOLR_URL', 'http://solr:8983/solr'))
    p.add_argument('--db-host', default=os.environ.get('DB_HOST', 'database'))
    p.add_argument('--db-name', default=os.environ.get('DB_NAME', 'emerse'))
    p.add_argument('--db-user', default=os.environ.get('DB_USER', 'emerse'))
    p.add_argument('--db-password-file', default=os.environ.get('DB_PASSWORD_FILE', '/run/secrets/emerse_db_password'))
    p.add_argument('--force', action='store_true', help='load files even if the ledger has them')
    p.add_argument('--dry-run', action='store_true', help='parse and count; touch neither database nor Solr')
    p.add_argument('--threads', type=int, default=4, help='concurrent Solr update requests (NLP runs in Solr)')
    p.add_argument('--batch-docs', type=int, default=200)
    p.add_argument('--batch-mb', type=int, default=8)
    p.add_argument('--commit-every', type=int, default=50, help='files between Solr commits')
    p.add_argument('--missing-age', type=int, default=-1, help="EMERSE's solr.missingAgeValue")
    p.add_argument('--debug', action='store_true', help='stop at the first failure with a traceback, which can quote PHI')
    args = p.parse_args()

    names = args.names or [n for n in os.listdir(args.exports) if n.endswith('.json')]
    names.sort(key=export_order)
    ledger_path = os.path.join(args.state, 'loaded.tsv')
    done = set() if args.force else read_ledger(ledger_path)
    todo = [n for n in names if n not in done]
    log(f'{len(todo)} of {len(names)} exports to load' + (' (dry run)' if args.dry_run else ''))
    if not todo:
        return 0

    solr = patients = db = None
    if not args.dry_run:
        os.makedirs(args.state, exist_ok=True)
        with open(args.db_password_file) as f:
            password = f.read().strip()
        db = pymysql.connect(host=args.db_host, user=args.db_user, password=password,
                             database=args.db_name, charset='utf8mb4', autocommit=False)
        with db.cursor() as c:
            c.execute('select SOURCE_KEY, DISPLAY_NAME from DOCUMENT_SOURCE')
            have = dict(c.fetchall())
        wrong = [f'{k} is "{have.get(k)}", not "{label}"' for label, k in SOURCES.items() if have.get(k) != label]
        if wrong:
            log('DOCUMENT_SOURCE does not match this loader:', '; '.join(wrong))
            log('Run database/initdb/91-chi-sources.sql (README, "Loading notes").')
            return 1
        patients = Patients(db)
        solr = Solr(args.solr, os.path.join(args.state, 'errors'))
        log(f'{len(patients.known):,} patients already in the database')

    totals = {'notes': 0, 'kept': 0, 'versions': 0, 'new': 0, 'changed': 0}
    skipped_total, failed = {}, []
    started = time.monotonic()
    with ThreadPoolExecutor(args.threads) as pool:
        for i, name in enumerate(todo, 1):
            t0 = time.monotonic()
            try:
                s = load_file(os.path.join(args.exports, name), args, solr, patients, pool)
            except Exception as e:
                # Only our own messages and JSON parse positions are printed: a database
                # error can quote a value ("Duplicate entry '<MRN>'"), so it shows its code.
                failed.append(name)
                if isinstance(e, (RuntimeError, json.JSONDecodeError)):
                    why = str(e)
                elif isinstance(e, pymysql.Error) and e.args:
                    why = f'MariaDB error {e.args[0]}'
                else:
                    why = 'see the traceback with --debug' if not args.debug else ''
                log(f'[{i}/{len(todo)}] {name}: FAILED: {type(e).__name__}: {why}')
                if args.debug:
                    raise
                if db:
                    db.rollback()
                continue
            for k in totals:
                totals[k] += s[k]
            for k, v in s['skipped'].items():
                skipped_total[k] = skipped_total.get(k, 0) + v
            skip = ', '.join(f'{v} {k}' for k, v in s['skipped'].items())
            log(f'[{i}/{len(todo)}] {name}: {s["kept"]:,} notes ({s["versions"]:,} older versions dropped'
                f'{", skipped " + skip if skip else ""}), {s["patients"]:,} patients'
                f' ({s["new"]:,} new, {s["changed"]:,} changed), {time.monotonic() - t0:.1f}s')
            if not args.dry_run:
                with open(ledger_path, 'a') as f:
                    f.write(f'{name}\t{s["kept"]}\t{dt.datetime.now():%Y-%m-%d %H:%M:%S}\n')
                if i % args.commit_every == 0:
                    solr.commit('documents')
    if solr:
        solr.commit('patient')
        solr.commit('documents')

    minutes = (time.monotonic() - started) / 60
    log(f'done in {minutes:.1f} min: {totals["kept"]:,} notes from {totals["notes"]:,} rows'
        f' ({totals["versions"]:,} older versions dropped), {totals["new"]:,} new patients,'
        f' {totals["changed"]:,} changed')
    for k, v in skipped_total.items():
        log(f'skipped {v:,} notes: {k}')
    for name in failed:
        log('FAILED', name)
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
