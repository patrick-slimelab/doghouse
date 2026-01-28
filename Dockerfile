# syntax=docker/dockerfile:1

# Build Moltbot in a dedicated stage
FROM node:22-bookworm AS builder

ARG MOLTBOT_REPO
ARG MOLTBOT_REF

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates openssh-client \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt
RUN git clone ${MOLTBOT_REPO} moltbot \
 && cd moltbot \
 && git checkout ${MOLTBOT_REF}

WORKDIR /opt/moltbot
RUN corepack enable \
 && pnpm install --frozen-lockfile \
 && pnpm build \
 && node ./moltbot.mjs plugins install @moltbot/matrix || true


# Runtime image
FROM node:22-bookworm

# Minimal deps for runtime + entrypoint privilege drop
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates tini gosu \
 && rm -rf /var/lib/apt/lists/*

# Copy built repo (including node_modules) with correct ownership in one shot.
# This avoids a slow recursive chown during build.
WORKDIR /home/node
COPY --from=builder --chown=node:node /opt/moltbot /home/node/moltbot

# Expose CLI on PATH (so `moltbot` / `clawdbot` work inside the container)
RUN ln -sf /home/node/moltbot/moltbot.mjs /usr/local/bin/moltbot \
 && ln -sf /home/node/moltbot/moltbot.mjs /usr/local/bin/clawdbot

ENV HOME=/home/node

COPY entrypoint.sh /usr/local/bin/doghouse-entrypoint
RUN chmod +x /usr/local/bin/doghouse-entrypoint

# Run entrypoint as root so it can fix volume ownership, then drop to node.
ENTRYPOINT ["/usr/bin/tini","--","/usr/local/bin/doghouse-entrypoint"]
CMD ["node","/home/node/moltbot/moltbot.mjs","gateway","start","--foreground"]
