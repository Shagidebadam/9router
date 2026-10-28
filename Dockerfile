# syntax=docker/dockerfile:1.7
# Optimized for Railway.app
ARG NODE_IMAGE=node:22-alpine
ARG ALPINE_MIRROR=dl-cdn.alpinelinux.org
ARG NPM_REGISTRY=https://registry.npmjs.org/
ARG APP_VERSION=unknown

# ─────────────────────────────────────────
# Base
# ─────────────────────────────────────────
FROM ${NODE_IMAGE} AS base
ARG ALPINE_MIRROR
WORKDIR /app

RUN if [ "$ALPINE_MIRROR" != "dl-cdn.alpinelinux.org" ]; then \
      sed -i "s|dl-cdn.alpinelinux.org|${ALPINE_MIRROR}|g" /etc/apk/repositories; \
    fi

# ─────────────────────────────────────────
# Builder
# ─────────────────────────────────────────
FROM base AS builder
ARG NPM_REGISTRY

RUN apk add --no-cache python3 make g++ linux-headers

COPY package.json ./
RUN npm install \
      --registry="${NPM_REGISTRY}" \
      --fetch-retries=5 \
      --fetch-retry-factor=2 \
      --fetch-retry-mintimeout=10000 \
      --fetch-retry-maxtimeout=120000 \
      --fetch-timeout=300000

COPY . ./
ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build

# Lazy runtime deps (wreq-js + playwright-core)
RUN mkdir -p /opt/lazy-runtime && cd /opt/lazy-runtime && \
    npm init -y >/dev/null && \
    npm install --no-save \
      --registry="${NPM_REGISTRY}" \
      --fetch-retries=5 \
      --fetch-retry-factor=2 \
      --fetch-retry-mintimeout=10000 \
      --fetch-retry-maxtimeout=120000 \
      --fetch-timeout=300000 \
      wreq-js playwright-core

# ─────────────────────────────────────────
# Runner (production)
# ─────────────────────────────────────────
FROM ${NODE_IMAGE} AS runner
ARG ALPINE_MIRROR
ARG APP_VERSION
WORKDIR /app

RUN if [ "$ALPINE_MIRROR" != "dl-cdn.alpinelinux.org" ]; then \
      sed -i "s|dl-cdn.alpinelinux.org|${ALPINE_MIRROR}|g" /etc/apk/repositories; \
    fi

LABEL org.opencontainers.image.title="9router" \
      org.opencontainers.image.version="${APP_VERSION}"

ENV NODE_ENV=production
ENV HOSTNAME=0.0.0.0
ENV NEXT_TELEMETRY_DISABLED=1
ENV DATA_DIR=/app/data
# PORT را Railway در runtime ست می‌کند — هاردکد نکن

COPY --from=builder /app/public ./public
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/custom-server.js ./custom-server.js
COPY --from=builder /app/open-sse ./open-sse
COPY --from=builder /app/src/mitm ./src/mitm
COPY --from=builder /app/node_modules/node-forge ./node_modules/node-forge
COPY --from=builder /app/node_modules/next ./node_modules/next
COPY --from=builder /app/node_modules/sql.js ./node_modules/sql.js
COPY --from=builder /app/node_modules/node-machine-id ./node_modules/node-machine-id

# wreq-js / playwright-core
COPY --from=builder /opt/lazy-runtime/node_modules/. ./node_modules/
COPY --from=builder /opt/lazy-runtime /app/data/runtime

RUN mkdir -p /app/data /app/data/runtime /app/data-home && \
    chown -R node:node /app && \
    ln -sf /app/data-home /root/.9router 2>/dev/null || true

RUN apk add --no-cache su-exec ffmpeg && \
  printf '#!/bin/sh\nchown -R node:node /app/data /app/data-home 2>/dev/null\nexec su-exec node "$@"\n' > /entrypoint.sh && \
  chmod +x /entrypoint.sh

# Railway خودش پورت را پروکسی می‌کند؛ EXPOSE فقط مستندسازی است
EXPOSE 3000

ENTRYPOINT ["/entrypoint.sh"]
CMD ["node", "custom-server.js"]
