# Docker Sandboxes (sbx) kit image: JetBrains Rider remote-dev backend + Mistral Vibe (ACP).
# Built by sbx from rider-sbx.yaml; see README.md "Rider in a Docker sandbox".
FROM ubuntu:24.04

ARG RIDER_VERSION=2026.2.3.1
ARG DOTNET_CHANNEL=9.0

USER root
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash ca-certificates curl git tar gzip unzip python3 procps \
        libxext6 libxrender1 libxtst6 libxi6 libfreetype6 fontconfig libgl1 libicu74 \
    && rm -rf /var/lib/apt/lists/*

# ubuntu:24.04 ships a default 'ubuntu' user with UID 1000; sbx requires 'agent' with UID 1000.
RUN userdel -r ubuntu 2>/dev/null || true \
    && groupadd --gid 1000 agent \
    && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash agent \
    && mkdir -p /home/agent/workspace /home/agent/.local/bin /home/agent/.local/share \
        /home/agent/.local/state /home/agent/.cache/rider-sbx /home/agent/.jetbrains \
        /home/agent/.docker/sandbox/locks \
    && chown -R agent:agent /home/agent

RUN touch /etc/sandbox-persistent.sh \
    && chown agent:agent /etc/sandbox-persistent.sh \
    && chmod 0644 /etc/sandbox-persistent.sh \
    && printf '%s\n' '. /etc/sandbox-persistent.sh' > /etc/profile.d/sandbox-persistent.sh \
    && printf '%s\n' '. /etc/sandbox-persistent.sh' >> /home/agent/.bashrc

# .NET SDK
RUN curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
    && bash /tmp/dotnet-install.sh --channel "${DOTNET_CHANNEL}" --install-dir /usr/share/dotnet \
    && ln -s /usr/share/dotnet/dotnet /usr/local/bin/dotnet \
    && rm /tmp/dotnet-install.sh

# JetBrains Rider (used headless as a remote-dev backend)
RUN curl -fsSL "https://download.jetbrains.com/rider/JetBrains.Rider-${RIDER_VERSION}.tar.gz" -o /tmp/rider.tar.gz \
    && mkdir -p /opt/rider \
    && tar -xzf /tmp/rider.tar.gz -C /opt/rider --strip-components=1 \
    && rm /tmp/rider.tar.gz \
    && chown -R agent:agent /opt/rider

COPY entrypoint.sh /usr/local/bin/rider-sbx-entrypoint
RUN chmod 0755 /usr/local/bin/rider-sbx-entrypoint

ENV HOME=/home/agent \
    PATH="/home/agent/.local/bin:/usr/share/dotnet:${PATH}" \
    BASH_ENV=/etc/sandbox-persistent.sh \
    DOTNET_ROOT=/usr/share/dotnet \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    IS_SANDBOX=1

USER agent

# Mistral Vibe (provides 'vibe' and 'vibe-acp') via uv
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/home/agent/.local/bin sh \
    && /home/agent/.local/bin/uv tool install mistral-vibe

# Register Vibe as an ACP agent for Rider's AI chat
COPY --chown=agent:agent acp.json /home/agent/.jetbrains/acp.json

WORKDIR /home/agent/workspace
EXPOSE 5990
ENTRYPOINT ["/usr/local/bin/rider-sbx-entrypoint"]
CMD []
