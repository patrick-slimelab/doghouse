FROM node:22-bookworm

ARG MOLTBOT_REPO
ARG MOLTBOT_REF

# Minimal deps for building + git operations
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates openssh-client tini gosu \
 && rm -rf /var/lib/apt/lists/*

# We'll build as root (needs permission to enable corepack / install deps).
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

# Ensure runtime user owns the app dir (avoid slow recursive chown if possible)
# NOTE: this is still somewhat expensive because node_modules is large.
RUN chown -R node:node /home/node/moltbot

# Expose CLI on PATH (so `moltbot` / `clawdbot` work inside the container)
RUN ln -sf /home/node/moltbot/moltbot.mjs /usr/local/bin/moltbot \
 && ln -sf /home/node/moltbot/moltbot.mjs /usr/local/bin/clawdbot

# Run
# NOTE: we run the gateway in the foreground so docker can manage restarts.
# Scoob will need to run onboarding once; state persists in the docker volume.

ENV HOME=/home/node

COPY entrypoint.sh /usr/local/bin/doghouse-entrypoint
RUN chmod +x /usr/local/bin/doghouse-entrypoint

# Run entrypoint as root so it can fix volume ownership, then drop to node.
ENTRYPOINT ["/usr/bin/tini","--","/usr/local/bin/doghouse-entrypoint"]
CMD ["node","./moltbot.mjs","gateway","start","--foreground"]
