# syntax=docker/dockerfile:1.7
FROM node:22-bookworm-slim AS build

ARG PNPM_VERSION=10.14.0
WORKDIR /source/examples/web_ui
COPY .build/agentscope-source/examples/web_ui/ ./
RUN corepack enable \
    && corepack prepare "pnpm@${PNPM_VERSION}" --activate \
    && pnpm install --frozen-lockfile \
    && pnpm build:frontend

FROM nginxinc/nginx-unprivileged:stable-alpine

ARG VCS_REF="unknown"
ARG SOURCE_URL="https://github.com/chadwangcn/agentscope-validation-lab"
LABEL org.opencontainers.image.title="AgentScope validation Web UI" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.revision="${VCS_REF}"

COPY deploy/oci/agentscope-web.nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /source/examples/web_ui/frontend/dist/ /usr/share/nginx/html/agentscope/
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/agentscope/"]
