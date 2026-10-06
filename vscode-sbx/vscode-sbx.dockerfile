# Docker Sandboxes (sbx) kit image: VS Code Remote-SSH backend + Mistral Vibe.
# Only the VS Code window runs on the host; the VS Code server, its extension host,
# the Mistral Vibe extension and all terminals run in here.
# Built by sbx from vscode-sbx.yaml; see README.md "VS Code in a Docker sandbox".
FROM ubuntu:24.04

ARG DOTNET_CHANNEL=9.0

USER root
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash ca-certificates curl wget git tar gzip unzip python3 procps openssh-server libicu74 \
    && rm -rf /var/lib/apt/lists/*

# ubuntu:24.04 ships a default 'ubuntu' user with UID 1000; sbx requires 'agent' with UID 1000.
RUN userdel -r ubuntu 2>/dev/null || true \
    && groupadd --gid 1000 agent \
    && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash agent \
    && usermod -p '*' agent \
    && mkdir -p /home/agent/workspace /home/agent/.local/bin /home/agent/.local/share \
        /home/agent/.local/state /home/agent/.docker/sandbox/locks \
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

COPY vscode-sbx-start.sh /usr/local/bin/vscode-sbx-start
RUN chmod 0755 /usr/local/bin/vscode-sbx-start

ENV HOME=/home/agent \
    PATH="/home/agent/.local/bin:/usr/share/dotnet:${PATH}" \
    BASH_ENV=/etc/sandbox-persistent.sh \
    DOTNET_ROOT=/usr/share/dotnet \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    IS_SANDBOX=1

USER agent

# Mistral Vibe CLI (usable from the VS Code terminal) via uv
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/home/agent/.local/bin sh \
    && /home/agent/.local/bin/uv tool install mistral-vibe

WORKDIR /home/agent/workspace
EXPOSE 2222
ENTRYPOINT ["/usr/local/bin/vscode-sbx-start", "--foreground"]
CMD []
