# TODO: implement — see docs/specs/lightrag-vault-indexer.md
FROM python:3.12-slim
RUN pip install --no-cache-dir requests
COPY indexer.py /app/indexer.py
COPY crontab /etc/cron.d/vault-indexer
RUN chmod 0644 /etc/cron.d/vault-indexer && crontab /etc/cron.d/vault-indexer
CMD ["crond", "-f"]
