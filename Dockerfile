FROM node:22-bookworm

ARG MOLTBOT_REPO
ARG MOLTBOT_REF

# Minimal deps for building + git operations
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates openssh-client tini \
 && rm -rf /var/lib/apt/lists/*

# We'll build as root (needs permission to enable corepack / install deps),
# then drop to the built-in non-root user `node` (uid 1000) at runtime.
USER root
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

# Ensure runtime user owns the app dir
RUN chown -R node:node /home/node/moltbot

# Run
# NOTE: we run the gateway in the foreground so docker can manage restarts.
# Scoob will need to run `moltbot onboard` in the container volume on first boot.

ENV HOME=/home/node

USER node

ENTRYPOINT ["/usr/bin/tini","--"]
CMD ["node","./moltbot.mjs","gateway","start","--foreground"]
