FROM python:3.12-slim
RUN pip install --no-cache-dir lightrag-mcp
EXPOSE 3002
CMD ["lightrag-mcp", \
     "--mcp-transport", "streamable-http", \
     "--mcp-host", "0.0.0.0", \
     "--mcp-port", "3002", \
     "--mcp-streamable-http-path", "/mcp", \
     "--mcp-stateless-http"]
