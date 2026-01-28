FROM node:22-bookworm

ARG MOLTBOT_REPO
ARG MOLTBOT_REF

# Minimal deps for building + git operations
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates openssh-client tini \
 && rm -rf /var/lib/apt/lists/*

# Non-root user
RUN useradd -m -u 1000 app
USER app
WORKDIR /home/app

# Clone Moltbot and checkout the requested ref
RUN git clone ${MOLTBOT_REPO} moltbot \
 && cd moltbot \
 && git checkout ${MOLTBOT_REF}

WORKDIR /home/app/moltbot

# Install + build
RUN corepack enable \
 && pnpm install --frozen-lockfile \
 && pnpm build

# Run
# NOTE: we run the gateway in the foreground so docker can manage restarts.
# Scoob will need to run `moltbot onboard` in the container volume on first boot.

ENV HOME=/home/app
ENTRYPOINT ["/usr/bin/tini","--"]
CMD ["node","./moltbot.mjs","gateway","start","--foreground"]
