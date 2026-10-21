# Sourced by the official run-initdb before Solr starts, so no exit and no exec. A fresh
# SOLR_HOME gets EMERSE's cores (without data), NLP models, dictionaries and the 7.2.1
# plugin. A home that already has cores, such as deploy.sh --demo's, is left as is.
if [ ! -d "$SOLR_HOME/documents" ]; then
	echo "Solr: seeding an empty EMERSE home in $SOLR_HOME"
	cp -R /opt/emerse/solr-home/. "$SOLR_HOME/"
fi
