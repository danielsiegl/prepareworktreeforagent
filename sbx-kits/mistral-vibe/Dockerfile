# syntax=docker/dockerfile:1
ARG BASE_IMAGE=docker/sandbox-templates:shell
FROM ${BASE_IMAGE}

# Pin the agent version for reproducible sandboxes.
# Check https://pypi.org/project/mistral-vibe/ and bump as needed.
ARG VIBE_VERSION=2.25.8

# .NET SDK channel/version to install (e.g. "10.0"). Installed via Microsoft's
# dotnet-install.sh script rather than apt, since the apt feed often lags behind
# the newest Ubuntu base images used by sandbox-templates.
ARG DOTNET_VERSION=10.0

# Install the .NET SDK system-wide (as root) so both the 'agent' user and the
# sandbox's own tooling can run 'dotnet'. The base image's default user isn't
# root, so switch explicitly before using apt-get.
USER root
RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
    && chmod +x /tmp/dotnet-install.sh \
    && /tmp/dotnet-install.sh --channel "${DOTNET_VERSION}" --install-dir /usr/share/dotnet \
    && rm /tmp/dotnet-install.sh \
    && /usr/share/dotnet/dotnet --version

ENV DOTNET_ROOT=/usr/share/dotnet
ENV PATH="${DOTNET_ROOT}:${PATH}"
ENV DOTNET_NOLOGO=1
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1

# Install Vibe as the non-root agent user. The socks extra is installed
# explicitly so the agent works through the sandbox proxy.
USER agent
RUN uv tool install "mistral-vibe==${VIBE_VERSION}" --with "httpx[socks]" \
    && vibe --version

CMD ["vibe", "--agent", "auto-approve"]