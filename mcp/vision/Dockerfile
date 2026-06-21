FROM python:3.12-slim
RUN pip install --no-cache-dir fastmcp httpx
COPY server.py /app/server.py
WORKDIR /app
EXPOSE 3003
CMD ["python", "/app/server.py"]
