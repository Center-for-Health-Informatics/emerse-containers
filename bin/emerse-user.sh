#!/bin/sh
# Create an EMERSE account for a CHI Authentication username, the way
# PersonDao.createLoginAccount does (external auth, no password), with the given roles.
#
#   bin/emerse-user.sh <username> <first> <last> [ROLE ...]
#
# Roles default to EMERSE_FULL. ADMIN is needed for the first account, which can then add
# everyone else in the EMERSE admin app. Role names are in the ROLE table: ADMIN,
# API_USER, EMERSE_FULL, EMERSE_AGG, EMERSE_MRN, EMERSE_LIST, MRN_DOWNLOAD,
# QUERY_WRITER_USER.
#
# The username must match CHI's SSO username exactly, case included (a UC 6+2 such as
# iretonrt, or an email address for Children's and email accounts).
set -eu
cd "$(dirname "$0")/.."
compose=${COMPOSE:-docker compose}

[ $# -ge 3 ] || { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
username=$1 first=$2 last=$3
shift 3
[ $# -gt 0 ] || set -- EMERSE_FULL

printf '%s' "$username" | grep -Eq '^[A-Za-z0-9@._+-]{1,50}$' || { echo "unexpected characters in username" >&2; exit 2; }
for r in "$@"; do printf '%s' "$r" | grep -Eq '^[A-Z_]+$' || { echo "bad role name: $r" >&2; exit 2; }; done
# names go into SQL string literals: refuse quotes and backslashes rather than escape them
for n in "$first" "$last"; do
	case "$n" in *\'*|*\\*) echo "quotes and backslashes aren't allowed in names" >&2; exit 2 ;; esac
done
roles=$(printf "'%s'," "$@"); roles=${roles%,}

sql() { $compose exec -T database sh -c 'exec mariadb -N -u emerse -p"$(cat /run/secrets/emerse_db_password)" emerse'; }

taken=$(echo "select count(*) from LOGIN_ACCOUNT where USER_ID = '$username';" | sql)
[ "$taken" = 0 ] || { echo "$username already has an EMERSE account" >&2; exit 1; }

sql <<SQL
start transaction;
set @party = next value for PARTY_SEQ;
set @login = next value for LOGIN_ACCOUNT_SEQ;
insert into PARTY (ID, NAME) values (@party, concat('$first', ' ', '$last'));
insert into LOGIN_ACCOUNT
	(ID, USER_ID, PASSWORD, ACTIVE_STATUS, EXTERNAL_AUTH, CREATION_DATE, UPDATE_DATE, CREATED_BY, MODIFIED_BY)
values
	(@login, '$username', 'unused', true, true, current_timestamp, current_timestamp, 'chi-cli', 'chi-cli');
insert into PERSON (ID, LOGIN_ID, FIRST_NAME, LAST_NAME) values (@party, @login, '$first', '$last');
-- ACL_ITEM group 2 is ROLE and verb 3 is the grant, as in the fresh-install seed rows
insert into ACL_ITEM (\`GROUP\`, MEMBER_ID, VERB, PARTY_ID)
	select 2, r.ID, 3, @party from ROLE r where r.NAME in ($roles);
commit;
select concat(la.USER_ID, ': ', group_concat(r.NAME order by r.NAME separator ', '))
  from LOGIN_ACCOUNT la
  join PERSON p on p.LOGIN_ID = la.ID
  join ACL_ITEM a on a.PARTY_ID = p.ID and a.\`GROUP\` = 2
  join ROLE r on r.ID = a.MEMBER_ID
 where la.ID = @login
 group by la.USER_ID;
SQL
