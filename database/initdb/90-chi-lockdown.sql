-- Runs once, right after fresh-install-v7.2.1.maria.sql, on an empty data volume.
--
-- The fresh install ships app accounts with well-known passwords (emerse/demouser,
-- mrnuser, listuser, and the aggregate user). EMERSE 7 still accepts HTTP Basic against
-- LOGIN_ACCOUNT.PASSWORD, so a known password would let anyone CHI Authentication lets
-- through act as that account. With no password and EXTERNAL_AUTH set (and no LDAP
-- profile) checkUsernamePassword can never succeed: preauth via CHI is the only way in.
-- 'unused' is what PersonDao.createLoginAccount stores for an external-auth account.
update `LOGIN_ACCOUNT`
   set `PASSWORD` = 'unused',
       `EXTERNAL_AUTH` = true,
       `UPDATE_DATE` = current_timestamp,
       `MODIFIED_BY` = 'chi-lockdown';
