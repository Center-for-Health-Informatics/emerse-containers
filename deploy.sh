#!/bin/sh

# unpack the Solr indexes, removing some backup files that should have been excluded from the source
mkdir -p $SOLR_HOME
unzip -n -d $SOLR_HOME $ASSETS/solr-indexes-7.0.0.zip
find $SOLR_HOME -name "*~" -delete

# modify the default emerse.properties file with local values
mkdir -p $EMERSE_HOME/etc
cat $ASSETS/emerse.properties \
  | sed "s/^ds\.password=.*/ds.password=$EMERSE_DB_PASSWORD/" \
  | sed "s/^ds\.url=jdbc:mariadb:\/\/localhost:3306\/emerse/ds.url=jdbc:mariadb:\/\/database:3306\/emerse/" \
  | sed "s/^solr\.serviceURL=http:\/\/localhost:8983\/solr\//solr.serviceURL=http:\/\/solr:8983\/solr\//" \
  | sed "s/^contact\.url=http:\/\/example\.org\//contact.url=https:\/\/chi.uc.edu\//" \
  | sed "s/^contact\.text=this page/contact.text=Center for Health Informatics/" \
  > $EMERSE_HOME/etc/emerse.properties
