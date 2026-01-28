FROM node:22-bookworm

ARG MOLTBOT_REPO
ARG MOLTBOT_REF

# Minimal deps for building + git operations
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates openssh-client tini \
 && rm -rf /var/lib/apt/lists/*

# Non-root user
# The official node image already has a non-root user `node` (uid 1000).
USER node
WORKDIR /home/node

# Clone Moltbot and checkout the requested ref
RUN git clone ${MOLTBOT_REPO} moltbot \
 && cd moltbot \
 && git checkout ${MOLTBOT_REF}

WORKDIR /home/node/moltbot

# Install + build
RUN corepack enable \
 && pnpm install --frozen-lockfile \
 && pnpm build

# Run
# NOTE: we run the gateway in the foreground so docker can manage restarts.
# Scoob will need to run `moltbot onboard` in the container volume on first boot.

ENV HOME=/home/node
ENTRYPOINT ["/usr/bin/tini","--"]
CMD ["node","./moltbot.mjs","gateway","start","--foreground"]
