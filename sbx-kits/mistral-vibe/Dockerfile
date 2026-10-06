# syntax=docker/dockerfile:1
ARG BASE_IMAGE=docker/sandbox-templates:shell
FROM ${BASE_IMAGE}

# Pin the agent version for reproducible sandboxes.
# Check https://pypi.org/project/mistral-vibe/ and bump as needed.
ARG VIBE_VERSION=2.24.5

# Install Vibe as the non-root agent user. The socks extra is installed
# explicitly so the agent works through the sandbox proxy.
USER agent
RUN uv tool install "mistral-vibe==${VIBE_VERSION}" --with "httpx[socks]" \
    && vibe --version

CMD ["vibe", "--agent", "auto-approve"]