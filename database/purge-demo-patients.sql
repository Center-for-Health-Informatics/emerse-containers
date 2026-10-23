-- Run once on escher, before or after loading (README, "Loading notes"); never on the
-- demo stack. Safe to repeat.
--
-- The fresh install's PATIENT table holds EMERSE's ~10,000 made-up demo patients. The
-- production index never gets their notes (download.sh drops the demo data), so they
-- would only inflate patient counts. Every real patient comes from the loader, which
-- marks it CREATED_BY 'chi-loader'; everything else goes, with the rows that refer to it:
-- patient-list entries, birth-date changes, and the views and audit rows of anyone who
-- tried the empty system. Patient lists themselves are kept, emptied.
create temporary table DEMO_PATIENT as
select `ID` from `PATIENT` where `CREATED_BY` is null or `CREATED_BY` <> 'chi-loader';

delete from `PATIENT_BIRTH_CHANGE` where `PATIENT_ID` in (select `ID` from DEMO_PATIENT);
delete from `PATIENT_LIST_ENTRY` where `PATIENT_ID` in (select `ID` from DEMO_PATIENT);
delete from `DOCUMENT_VIEW` where `PATIENT_ID` in (select `ID` from DEMO_PATIENT);
delete from `SEARCH_AUDIT_SPECIFIC` where `PATIENT_ID` in (select `ID` from DEMO_PATIENT);
delete from `PATIENT` where `ID` in (select `ID` from DEMO_PATIENT);
select row_count() as demo_patients_deleted;
