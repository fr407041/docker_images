FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    git \
    gnupg \
    jq \
    less \
    procps \
    python3 \
    python3-pytest \
    python3-pip \
    sudo \
    vim \
    wget \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code @musistudio/claude-code-router @openai/codex

RUN useradd -m -s /bin/bash claude \
    && mkdir -p /home/claude/.claude-code-router /workspace /opt/claude-ccr \
    && chown -R claude:claude /home/claude /workspace

COPY router-config.json /opt/claude-ccr/router-config.json
COPY strip-thinking-transformer.js /opt/claude-ccr/strip-thinking-transformer.js
COPY start-ccr.sh /usr/local/bin/start-ccr
COPY run-claude.sh /usr/local/bin/run-claude
COPY run-codex.sh /usr/local/bin/run-codex
COPY smoke-test.sh /usr/local/bin/smoke-test-ccr

RUN chmod +x /usr/local/bin/start-ccr /usr/local/bin/run-claude /usr/local/bin/run-codex /usr/local/bin/smoke-test-ccr

ENV ANTHROPIC_AUTH_TOKEN=local-test-key
ENV ANTHROPIC_BASE_URL=http://127.0.0.1:3456
ENV NO_PROXY=127.0.0.1,localhost
ENV DISABLE_PROMPT_CACHING=1
ENV API_TIMEOUT_MS=600000
ENV HOME=/home/claude

WORKDIR /workspace
USER claude

CMD ["/bin/bash"]
