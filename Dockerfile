# syntax=docker/dockerfile:1

# --- Stage 1: Build OpenClaw ---
FROM node:22-bookworm AS builder

ARG MOLTBOT_REPO
ARG MOLTBOT_REF
ARG MOLTBOT_CACHE_BUST

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates openssh-client \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt
# Cache bust to force pulling latest branch head when building from a moving ref.
RUN echo "MOLTBOT_CACHE_BUST=${MOLTBOT_CACHE_BUST:-0}" \
 && git clone ${MOLTBOT_REPO} openclaw \
 && cd openclaw \
 && git checkout ${MOLTBOT_REF}

WORKDIR /opt/openclaw
RUN corepack enable \
 && pnpm install --frozen-lockfile \
 && pnpm build


# --- Stage 2: Runtime image ---
FROM node:22-bookworm

# Minimal deps for runtime + entrypoint privilege drop + sudo + curl/jq + sshd
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates tini gosu sudo curl jq openssh-server ripgrep gh \
 && rm -rf /var/lib/apt/lists/*

# Install cloudflared (for Dongometer tunnel)
RUN curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared \
 && chmod +x /usr/local/bin/cloudflared

# Install mongosh (used by discord-indexer-search / Mongo inspection)
RUN curl -fsSL https://downloads.mongodb.com/compass/mongosh-2.3.8-linux-x64.tgz -o /tmp/mongosh.tgz \
 && tar -xzf /tmp/mongosh.tgz -C /tmp \
 && mv /tmp/mongosh-*/bin/mongosh /usr/local/bin/mongosh \
 && chmod +x /usr/local/bin/mongosh \
 && rm -rf /tmp/mongosh.tgz /tmp/mongosh-*

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

# Copy built OpenClaw to /opt (avoid putting it under /home/scoob because volumes can shadow it)
WORKDIR /home/scoob
COPY --from=builder /opt/openclaw /opt/openclaw
RUN chmod +x /opt/openclaw/dist/entry.js

# Expose CLI on PATH
# NOTE: "moltbot" is deprecated; keep it as a compatibility alias.
RUN ln -sf /opt/openclaw/dist/entry.js /usr/local/bin/openclaw \
 && ln -sf /opt/openclaw/dist/entry.js /usr/local/bin/openpaw \
 && ln -sf /opt/openclaw/dist/entry.js /usr/local/bin/moltbot \
 && ln -sf /opt/openclaw/dist/entry.js /usr/local/bin/clawdbot

ENV HOME=/home/scoob

COPY entrypoint.sh /usr/local/bin/doghouse-entrypoint
COPY scripts/ /opt/doghouse/scripts/
RUN chmod +x /usr/local/bin/doghouse-entrypoint \
 && chmod -R +x /opt/doghouse/scripts

# Run entrypoint as root so it can fix volume ownership, then drop to scoob.
ENTRYPOINT ["/usr/bin/tini","--","/usr/local/bin/doghouse-entrypoint"]
CMD ["openclaw","gateway","run","--port","4000","--allow-unconfigured"]
