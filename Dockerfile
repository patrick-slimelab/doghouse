# syntax=docker/dockerfile:1

# --- Stage 1: Build OpenClaw (scrappy) ---
FROM node:22-bookworm AS builder

ARG MOLTBOT_REPO=https://github.com/patrick-slimelab/openclaw.git
ARG MOLTBOT_REF=main

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates openssh-client \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt
RUN git clone ${MOLTBOT_REPO} openclaw \
 && cd openclaw \
 && git checkout ${MOLTBOT_REF}

WORKDIR /opt/openclaw
RUN corepack enable && pnpm install && pnpm build

# --- Stage 2: Build Discord Indexer (.NET) ---
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS dotnet-builder
WORKDIR /src

# Discord
COPY discord-indexer.NET/ ./discord-indexer.NET/
RUN dotnet restore -r linux-x64 ./discord-indexer.NET/discord-indexer.csproj
RUN dotnet publish ./discord-indexer.NET/discord-indexer.csproj -c Release -r linux-x64 -o /out/discord-indexer --no-restore -p:PublishSingleFile=true -p:PublishTrimmed=false

# --- Stage 3: Runtime Image ---
FROM node:22-bookworm

# Install gh CLI keyring and repo
RUN mkdir -p -m 755 /etc/apt/keyrings \
 && wget -nv -O /etc/apt/keyrings/githubcli-archive-keyring.gpg https://cli.github.com/packages/githubcli-archive-keyring.gpg \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null

# Minimal deps + gh + entrypoint tools
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    ca-certificates tini gosu sudo curl jq openssh-server \
    gh \
 && rm -rf /var/lib/apt/lists/*

# Install mongosh manually
RUN curl -fsSL https://downloads.mongodb.com/compass/mongosh-2.3.8-linux-x64.tgz -o mongosh.tgz \
 && tar -xzf mongosh.tgz \
 && mv mongosh-*-linux-x64/bin/mongosh /usr/local/bin/ \
 && rm -rf mongosh.tgz mongosh-*-linux-x64

# Create scrappy user (passwordless sudo *inside the container*)
RUN useradd -m -u 1001 -s /bin/bash scrappy \
 && usermod -aG sudo scrappy \
 && echo "scrappy ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/scrappy \
 && chmod 0440 /etc/sudoers.d/scrappy

# Configure SSHD (listen on 2222, allow scrappy, custom authorized_keys path)
RUN mkdir /var/run/sshd \
 && echo "Port 2222" >> /etc/ssh/sshd_config \
 && echo "PermitRootLogin no" >> /etc/ssh/sshd_config \
 && echo "PasswordAuthentication no" >> /etc/ssh/sshd_config \
 && echo "AllowUsers scrappy" >> /etc/ssh/sshd_config \
 && echo "AuthorizedKeysFile /tmp/ssh/%u" >> /etc/ssh/sshd_config

# Copy built OpenClaw
WORKDIR /home/scrappy
COPY --from=builder /opt/openclaw /opt/openclaw
RUN ln -sf /opt/openclaw /home/scrappy/openclaw \
 && chmod +x /opt/openclaw/dist/entry.js \
 && chmod +x /home/scrappy/openclaw/dist/entry.js

# Copy built indexer
COPY --from=dotnet-builder /out/discord-indexer/discord-indexer /usr/local/bin/discord-indexer
RUN chmod +x /usr/local/bin/discord-indexer

# Expose CLI on PATH
RUN ln -sf /opt/openclaw/dist/entry.js /usr/local/bin/openclaw \
 && ln -sf /opt/openclaw/dist/entry.js /usr/local/bin/moltbot \
 && ln -sf /opt/openclaw/dist/entry.js /usr/local/bin/clawdbot

ENV HOME=/home/scrappy

COPY entrypoint.sh /usr/local/bin/doghouse-entrypoint
RUN chmod +x /usr/local/bin/doghouse-entrypoint

COPY query-matrix.sh /usr/local/bin/query-matrix
RUN chmod +x /usr/local/bin/query-matrix

ENTRYPOINT ["tini", "--", "/usr/local/bin/doghouse-entrypoint"]
