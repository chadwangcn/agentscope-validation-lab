# syntax=docker/dockerfile:1.7
FROM node:22-bookworm-slim AS frontend

WORKDIR /build
COPY talk-think-memory-lab/frontend/package.json talk-think-memory-lab/frontend/package-lock.json ./
RUN npm ci
COPY talk-think-memory-lab/frontend/ ./
RUN npm run build

FROM python:3.12-slim-bookworm AS build

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:$PATH
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential \
    && find /var/lib/apt/lists -mindepth 1 -delete \
    && python -m venv /opt/venv
COPY .build/agentscope-source/ /agentscope-source/
WORKDIR /source
COPY talk-think-memory-lab/pyproject.toml ./
COPY talk-think-memory-lab/app ./app
RUN python -m pip install --upgrade pip setuptools wheel \
    && python -m pip install /agentscope-source \
    && python -m pip install /source

FROM python:3.12-slim-bookworm

ARG VCS_REF="unknown"
ARG SOURCE_URL="https://github.com/chadwangcn/agentscope-validation-lab"
LABEL org.opencontainers.image.title="Talk Think Memory validation lab" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.revision="${VCS_REF}"

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:$PATH \
    LAB_DATA_DIR=/var/lib/talk-think-memory-lab \
    LAB_FRONTEND_DIST=/opt/talk-think-memory-lab/frontend/dist \
    REME_BASE_URL=http://reme:12333 \
    NEO4J_URI=bolt://neo4j:7687

COPY --from=build /opt/venv /opt/venv
RUN groupadd --system --gid 10002 talkthinklab \
    && useradd --system --uid 10002 --gid talkthinklab \
      --home-dir /var/lib/talk-think-memory-lab talkthinklab \
    && install -d -o talkthinklab -g talkthinklab \
      /var/lib/talk-think-memory-lab /opt/talk-think-memory-lab/frontend/dist
COPY --from=frontend --chown=talkthinklab:talkthinklab /build/dist/ /opt/talk-think-memory-lab/frontend/dist/
COPY --chmod=0755 deploy/oci/reme-no-provider /usr/local/bin/reme-no-provider

WORKDIR /var/lib/talk-think-memory-lab
USER 10002:10002
EXPOSE 18280
VOLUME ["/var/lib/talk-think-memory-lab"]
HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:18280/health', timeout=2)"]
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "18280", "--timeout-graceful-shutdown", "10"]
