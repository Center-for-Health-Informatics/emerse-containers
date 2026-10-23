# The note loader (loader/load-notes.py), run on demand: `docker compose run --rm loader`.
# Build context is the repo root (build.sh).
FROM docker.io/library/python:3.13-slim
RUN pip install --no-cache-dir PyMySQL==1.1.1
COPY loader/load-notes.py /usr/local/bin/load-notes
# root, to read exports that are mode 600 like any PHI; it reaches only the backend network
ENTRYPOINT ["python3", "-I", "/usr/local/bin/load-notes"]
