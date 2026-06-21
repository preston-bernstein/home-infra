FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends cron && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir requests
COPY indexer.py /app/indexer.py
COPY crontab /tmp/vault-indexer-cron
RUN crontab /tmp/vault-indexer-cron && rm /tmp/vault-indexer-cron
CMD ["cron", "-f"]
