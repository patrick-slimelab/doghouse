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

# Minimal deps for runtime + entrypoint privilege drop + sudo + curl/jq (for model probing) + sshd
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates tini gosu sudo curl jq openssh-server \
 && rm -rf /var/lib/apt/lists/*

# Create scoob user (passwordless sudo *inside the container*)
RUN useradd -m -u 1001 -s /bin/bash scoob \
 && usermod -aG sudo scoob \
 && echo 'scoob ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/scoob \
 && chmod 0440 /etc/sudoers.d/scoob

# Configure SSHD (listen on 2222, allow scoob, custom authorized_keys path)
RUN mkdir /var/run/sshd \
 && echo 'Port 2222' >> /etc/ssh/sshd_config \
 && echo 'PermitRootLogin no' >> /etc/ssh/sshd_config \
 && echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config \
 && echo 'AllowUsers scoob' >> /etc/ssh/sshd_config \
 && echo 'AuthorizedKeysFile /tmp/ssh/%u' >> /etc/ssh/sshd_config

# Copy built repo (including node_modules) with correct ownership in one shot.
# This avoids a slow recursive chown during build.
WORKDIR /home/scoob
COPY --from=builder --chown=scoob:scoob /opt/moltbot /home/scoob/moltbot

# Expose CLI on PATH (so `moltbot` / `clawdbot` work inside the container)
RUN ln -sf /home/scoob/moltbot/moltbot.mjs /usr/local/bin/moltbot \
 && ln -sf /home/scoob/moltbot/moltbot.mjs /usr/local/bin/clawdbot

ENV HOME=/home/scoob

COPY entrypoint.sh /usr/local/bin/doghouse-entrypoint
RUN chmod +x /usr/local/bin/doghouse-entrypoint

# Run entrypoint as root so it can fix volume ownership, then drop to node.
ENTRYPOINT ["/usr/bin/tini","--","/usr/local/bin/doghouse-entrypoint"]
CMD ["node","/home/scoob/moltbot/moltbot.mjs","gateway","run","--bind","loopback","--allow-unconfigured"]
