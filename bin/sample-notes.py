#!/usr/bin/env python3
# Copy a patient sample of the weekly note exports, for an index smaller than the full one.
#
# Each export is a JSON array of notes, one file per note type and week. A patient is kept
# when a salted SHA-256 of their MRN falls below --fraction. All of that patient's notes
# are kept, so timelines stay whole and note types keep their proportions. The choice
# depends only on the MRN, so later exports pick the same patients, and a larger fraction
# keeps every patient a smaller one picked.
#
# Prints counts only, never note contents. The output is still PHI.
#
#   bin/sample-notes.py --dry-run SRC                # report totals and the sample size
#   bin/sample-notes.py --fraction 0.01 SRC DEST     # write the sampled exports to DEST
import argparse
import hashlib
import json
import os
import sys
from concurrent.futures import ProcessPoolExecutor


def selected(mrn, salt, cutoff):
    digest = hashlib.sha256((salt + str(mrn)).encode()).digest()
    return int.from_bytes(digest[:8], 'big') < cutoff


def sample_file(src, dest, salt, cutoff):
    with open(src, encoding='utf-8') as f:
        notes = json.load(f)
    kept = [n for n in notes if selected(n['MRN'], salt, cutoff)]
    bytes_out = 0
    if dest and kept:
        with open(dest, 'w', encoding='utf-8') as f:
            json.dump(kept, f, ensure_ascii=False)
        bytes_out = os.path.getsize(dest)
    return (len(notes), len(kept), {str(n['MRN']) for n in notes},
            {str(n['MRN']) for n in kept}, bytes_out)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('src')
    p.add_argument('dest', nargs='?')
    p.add_argument('--fraction', type=float, default=0.01, help='share of patients kept (default 0.01)')
    p.add_argument('--salt', default='emerse7-sample', help='change to draw a different sample')
    p.add_argument('--jobs', type=int, default=4, help='files parsed in parallel; the largest takes ~5 GB of RAM')
    p.add_argument('--dry-run', action='store_true', help='count only; write nothing')
    args = p.parse_args()
    if not args.dry_run and not args.dest:
        p.error('DEST is required unless --dry-run')
    if not 0 < args.fraction <= 1:
        p.error('--fraction must be in (0, 1]')

    cutoff = int(args.fraction * 2**64)
    names = [n for n in os.listdir(args.src) if n.endswith('.json')]
    names.sort(key=lambda n: os.path.getsize(os.path.join(args.src, n)), reverse=True)
    dest = None if args.dry_run else args.dest
    if dest:
        os.makedirs(dest, exist_ok=True)

    notes_in = notes_out = bytes_out = 0
    bytes_in = sum(os.path.getsize(os.path.join(args.src, n)) for n in names)
    patients_in, patients_out, failed = set(), set(), []
    with ProcessPoolExecutor(args.jobs) as pool:
        futures = {n: pool.submit(sample_file, os.path.join(args.src, n),
                                  dest and os.path.join(dest, n), args.salt, cutoff)
                   for n in names}
        for i, (name, fut) in enumerate(futures.items(), 1):
            try:
                n_in, n_out, p_in, p_out, b_out = fut.result()
            except Exception as e:
                # the exception type only: a message could quote note text
                failed.append(f'{name}: {type(e).__name__}')
                continue
            notes_in += n_in
            notes_out += n_out
            bytes_out += b_out
            patients_in |= p_in
            patients_out |= p_out
            if i % 500 == 0:
                print(f'{i}/{len(names)} files', file=sys.stderr)

    mb = 2**20
    print(f'files     {len(names) - len(failed):>12,} read, {len(failed)} failed')
    print(f'patients  {len(patients_in):>12,} -> {len(patients_out):,}')
    print(f'notes     {notes_in:>12,} -> {notes_out:,}')
    if dest:
        print(f'MB        {bytes_in / mb:>12,.1f} -> {bytes_out / mb:,.1f}')
    else:
        print(f'MB        {bytes_in / mb:>12,.1f} -> ~{bytes_in * notes_out / max(notes_in, 1) / mb:,.1f} (estimate)')
    for f in failed:
        print('FAILED', f, file=sys.stderr)
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
