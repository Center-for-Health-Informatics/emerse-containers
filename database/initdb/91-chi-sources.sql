-- Runs once, after 90-chi-lockdown.sql, on an empty data volume. On a database that
-- already exists, run it by hand (README, "Loading notes"); it is safe to repeat.
--
-- Our exports' NoteSource values are Main EHR, Radiology, Pathology and Cardiology.
-- 7.2 ships source5 as "Scanned/PDFs" with the OCR viewer; we have no scans, so source5
-- carries Cardiology (as it did in v6) and shows as HTML like the others. On the demo
-- stack, this shows the demo's 32 scanned documents as HTML.
update `DOCUMENT_SOURCE`
   set `DISPLAY_NAME` = 'Cardiology', `DISPLAY_TYPE` = 'HTML'
 where `SOURCE_KEY` = 'source5';
update `FIELD` f join `DOCUMENT_SOURCE` s on s.`ID` = f.`SOURCE_ID`
   set f.`LABEL` = 'Department'
 where s.`SOURCE_KEY` = 'source5' and f.`NAME` = 'DEPT';
