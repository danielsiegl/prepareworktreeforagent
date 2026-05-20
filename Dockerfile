FROM node:22-bookworm

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ripgrep ca-certificates openssh-client \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g @openai/codex

WORKDIR /workspace
CMD ["codex"]
