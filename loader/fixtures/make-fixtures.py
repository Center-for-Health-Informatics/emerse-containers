#!/usr/bin/env python3
# Write made-up exports in the shape of the real ones, for testing load-notes.py anywhere.
# Everything is synthetic: MRNs start with 9 (real ones in the export don't), names are
# drawn from short lists. Covers what the real exports have: several versions of one
# NoteID, Cardiology and other sources, literal "<" and "&", four-space line breaks,
# bullets, a patient with no DOB, deceased patients, and a few notes the loader must skip.
#
#   loader/fixtures/make-fixtures.py DEST [--patients 50] [--notes 400]
import argparse
import datetime as dt
import json
import os
import random

TYPES = {'progress_notes': 'Progress Notes', 'consults': 'Consults', 'h_p': 'H&P',
         'echo': 'Transthoracic Echo (TTE) Complete', 'imaging': 'Imaging Report',
         'path': 'Surgical Pathology Report'}
SOURCE = {'echo': 'Cardiology', 'imaging': 'Radiology', 'path': 'Pathology'}
FIRST = ['Alex', 'Jordan', 'Casey', 'Riley', 'Morgan', 'Taylor', 'Jamie', 'Avery']
LAST = ['Testpatient', 'Fixture', 'Synthetic', 'Example', 'Sample']
RACES = ['White or Caucasian', 'Black or African American', 'Asian', 'Multiracial', 'Patient Refused']
ETHS = ['Not Hispanic or Latino', 'Hispanic or Latino', 'Unknown']
SENTENCES = [
    'Patient seen in clinic today for follow-up of type 2 diabetes.',
    'Denies chest pain, fevers or shortness of breath.',
    'No family history of colon cancer.',
    'Mother had breast cancer at 52.',
    'Possible early pneumonia; will obtain chest x-ray.',
    'A1c <7 & BP 128/82, both at goal.',
    'Plan:    • continue metformin 500 mg    • recheck labs in 3 months',
    'Left ventricular ejection fraction is 55-60%.',
]
WEEKS = [(dt.date(2026, 1, 1) + dt.timedelta(7 * i), dt.date(2026, 1, 8) + dt.timedelta(7 * i)) for i in range(3)]


def iso(t):
    return t.strftime('%Y-%m-%dT%H:%M:%S')


def main():
    p = argparse.ArgumentParser()
    p.add_argument('dest')
    p.add_argument('--patients', type=int, default=50)
    p.add_argument('--notes', type=int, default=400)
    p.add_argument('--seed', type=int, default=7)
    args = p.parse_args()
    rnd = random.Random(args.seed)

    patients = []
    for i in range(args.patients):
        birth = dt.datetime(1930, 1, 1) + dt.timedelta(days=rnd.randrange(365 * 95))
        patients.append({
            'MRN': f'9{i:07d}', 'FirstName': rnd.choice(FIRST), 'LastName': rnd.choice(LAST),
            'DOB': None if i == 0 else iso(birth), 'DOD': iso(birth + dt.timedelta(days=30000)) if i % 17 == 3 else None,
            'Gender': rnd.choice(['Female', 'Male', 'Not Reported'] if i % 13 == 0 else ['Female', 'Male']),
            'Race': rnd.choice(RACES), 'Ethnicity': rnd.choice(ETHS),
        })

    files = {}
    for n in range(args.notes):
        key = rnd.choice(list(TYPES))
        week = rnd.choice(WEEKS)
        pat = rnd.choice(patients)
        enc = dt.datetime.combine(week[0], dt.time()) + dt.timedelta(minutes=rnd.randrange(7 * 24 * 60))
        note = {**pat, 'NoteID': str(3_000_000_000 + n), 'NoteCSN': f'{4_000_000_000 + 10 * n}.0',
                'EncounterCSN': f'{5_000_000_000 + n // 2}.0', 'EncounterDate': iso(enc), 'NoteDate': iso(enc),
                'NoteType': TYPES[key], 'NoteSource': SOURCE.get(key, 'Main EHR'),
                'Department': 'UCMC FIXTURE CLINIC', 'Provider': 'Fixture, Doctor MD',
                'NoteText': '    '.join(rnd.sample(SENTENCES, 3))}
        rows = files.setdefault(f'{key}_{week[0]:%Y_%m_%d}_{week[1]:%Y_%m_%d}.json', [])
        rows.append(note)
        # an addendum: the same NoteID, a later NoteDate and CSN, longer text
        if n % 9 == 0:
            later = {**note, 'NoteCSN': f'{4_000_000_000 + 10 * n + 1}.0',
                     'NoteDate': iso(enc + dt.timedelta(hours=5)), 'NoteText': note['NoteText'] + '    ADDENDUM: reviewed.'}
            rows.insert(0, later)  # out of order on purpose
    first = files[sorted(files)[0]]
    first.append({**first[0], 'NoteID': '', 'NoteCSN': '1.0'})
    first.append({**first[0], 'NoteID': '3999999998', 'NoteSource': 'Scanned Media', 'NoteCSN': '2.0'})
    first.append({**first[0], 'NoteID': '3999999999', 'EncounterDate': 'not a date', 'NoteCSN': '3.0'})

    os.makedirs(args.dest, exist_ok=True)
    for name, rows in files.items():
        with open(os.path.join(args.dest, name), 'w', encoding='utf-8') as f:
            json.dump(rows, f, ensure_ascii=False)
    print(f'{sum(map(len, files.values()))} rows in {len(files)} files in {args.dest}')


if __name__ == '__main__':
    main()
