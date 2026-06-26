FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PLAYBOOK_ROOT=/opt/codex-claude-server-playbook

WORKDIR ${PLAYBOOK_ROOT}

COPY . ${PLAYBOOK_ROOT}

RUN chmod +x ${PLAYBOOK_ROOT}/scripts/*.sh \
 && apt-get update \
 && apt-get install -y \
    bash \
    ca-certificates \
    curl \
    git \
    jq \
    python3 \
    python3-pytest \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

CMD ["/bin/bash"]
