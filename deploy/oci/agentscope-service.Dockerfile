# syntax=docker/dockerfile:1.7
FROM python:3.12-slim-bookworm AS wheels

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1
WORKDIR /source
COPY .build/agentscope-source/ /source/
RUN python -m pip wheel --wheel-dir /wheels \
    "/source[service,storage-redis,tools,rag,vdb-qdrant]"

FROM python:3.12-slim-bookworm

ARG VCS_REF="unknown"
ARG SOURCE_URL="https://github.com/chadwangcn/agentscope-validation-lab"
LABEL org.opencontainers.image.title="AgentScope validation service" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.revision="${VCS_REF}"

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH=/opt/agentscope/source/src \
    AGENTSCOPE_REDIS_HOST=redis \
    AGENTSCOPE_REDIS_PORT=6379 \
    AGENTSCOPE_ENABLE_BROWSER_MCP=false \
    AGENTSCOPE_WORKSPACE_DIR=/var/lib/agentscope/workspaces

COPY --from=wheels /wheels /wheels
RUN python -m pip install --no-index --find-links=/wheels \
      "agentscope[service,storage-redis,tools,rag,vdb-qdrant]==2.0.5" \
    && find /wheels -mindepth 1 -delete \
    && groupadd --system --gid 10001 agentscope \
    && useradd --system --uid 10001 --gid agentscope --home-dir /var/lib/agentscope agentscope \
    && install -d -o agentscope -g agentscope /var/lib/agentscope/workspaces

COPY --from=wheels --chown=agentscope:agentscope /source /opt/agentscope/source
WORKDIR /opt/agentscope/source/examples/agent_service
USER 10001:10001
EXPOSE 18080
VOLUME ["/var/lib/agentscope"]
HEALTHCHECK --interval=30s --timeout=3s --start-period=20s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:18080/openapi.json', timeout=2)"]
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "18080", "--timeout-graceful-shutdown", "10"]
