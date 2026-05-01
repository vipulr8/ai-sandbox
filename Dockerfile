FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# ── Layer 1: System packages ─────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    make \
    gcc \
    g++ \
    curl \
    wget \
    ca-certificates \
    gnupg \
    git \
    jq \
    ripgrep \
    fd-find \
    unzip \
    zip \
    xz-utils \
    python3 \
    python3-pip \
    python3-venv \
    bash \
    bash-completion \
    sudo \
    locales \
    apt-transport-https \
    openssh-client \
    vim \
    nano \
    tmux \
    tree \
    shellcheck \
    htop \
    zsh \
    openjdk-21-jdk-headless \
    && rm -rf /var/lib/apt/lists/*

RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# fd-find is packaged as fdfind on Ubuntu
RUN ln -sf "$(which fdfind)" /usr/local/bin/fd

# ── uv (Python package manager) ───────────────────────────────────
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && mv /root/.local/bin/uv /usr/local/bin/ \
    && mv /root/.local/bin/uvx /usr/local/bin/

# ── GitHub CLI ────────────────────────────────────────────────────
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# ── Layer 2: Go ───────────────────────────────────────────────────
ARG GO_VERSION=1.24.2
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-$(dpkg --print-architecture).tar.gz" \
    | tar -C /usr/local -xz
ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOPATH="/home/coder/go"
ENV PATH="${GOPATH}/bin:${PATH}"

# ── Gitleaks ──────────────────────────────────────────────────────
ARG GITLEAKS_VERSION=8.24.3
RUN ARCH="$(dpkg --print-architecture)" \
    && if [ "$ARCH" = "amd64" ]; then GL_ARCH="x64"; else GL_ARCH="$ARCH"; fi \
    && curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_${GL_ARCH}.tar.gz" \
    | tar -C /usr/local/bin -xz gitleaks

# ── Layer 3: Rust ─────────────────────────────────────────────────
ENV RUSTUP_HOME="/usr/local/rustup"
ENV CARGO_HOME="/usr/local/cargo"
ENV PATH="${CARGO_HOME}/bin:${PATH}"
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable --profile minimal \
    && chmod -R a+rw "${RUSTUP_HOME}" "${CARGO_HOME}"

# ── Layer 4: Node.js 22 LTS ──────────────────────────────────────
ARG NODE_MAJOR=22
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && corepack enable

# ── Layer 5: Docker CLI (socket-mount only, no daemon) ────────────
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
       -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
       https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# ── Layer 6: Non-root user ───────────────────────────────────────
ARG USER_NAME=coder
ARG USER_UID=1000
ARG USER_GID=1000

RUN userdel -r "$(getent passwd ${USER_UID} | cut -d: -f1)" 2>/dev/null || true \
    && groupdel "$(getent group ${USER_GID} | cut -d: -f1)" 2>/dev/null || true \
    && groupadd --gid "${USER_GID}" "${USER_NAME}" \
    && useradd --uid "${USER_UID}" --gid "${USER_GID}" -m -s /bin/bash "${USER_NAME}" \
    && echo "${USER_NAME} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/"${USER_NAME}" \
    && chmod 0440 /etc/sudoers.d/"${USER_NAME}"

# ── Layer 7: Claude Code CLI ─────────────────────────────────────
ARG CLAUDE_VERSION=latest
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_VERSION}" \
    && npm cache clean --force

# ── Container hooks and settings ─────────────────────────────────
COPY container-hooks/ /opt/ai-sandbox/hooks/
RUN chmod +x /opt/ai-sandbox/hooks/*.sh
COPY container-settings.json /opt/ai-sandbox/settings.json

# ── Starship prompt ───────────────────────────────────────────────
RUN curl -fsSL https://starship.rs/install.sh | sh -s -- -y

# ── Global git hooks (gitleaks pre-commit) ────────────────────────
COPY container-hooks/git/ /opt/ai-sandbox/git-hooks/
RUN chmod +x /opt/ai-sandbox/git-hooks/* \
    && git config --system core.hooksPath /opt/ai-sandbox/git-hooks

# ── Layer 8: User environment ────────────────────────────────────
USER ${USER_NAME}
WORKDIR /home/${USER_NAME}

RUN mkdir -p /home/${USER_NAME}/project \
    && mkdir -p /home/${USER_NAME}/.local/bin

# Set zsh as default shell
RUN sudo chsh -s "$(which zsh)" "${USER_NAME}"

COPY --chown=${USER_NAME}:${USER_NAME} entrypoint.sh /home/${USER_NAME}/entrypoint.sh
RUN chmod +x /home/${USER_NAME}/entrypoint.sh

# ── vim config ────────────────────────────────────────────────────
RUN cat > /home/${USER_NAME}/.vimrc <<'VIMRC'
syntax on
set number
set relativenumber
set tabstop=4
set shiftwidth=4
set expandtab
set autoindent
set hlsearch
set incsearch
set ignorecase
set smartcase
set cursorline
set wildmenu
set showmatch
colorscheme desert
VIMRC

# ── zsh plugins ───────────────────────────────────────────────────
RUN git clone https://github.com/zsh-users/zsh-autosuggestions /home/${USER_NAME}/.zsh/zsh-autosuggestions \
    && git clone https://github.com/zsh-users/zsh-syntax-highlighting /home/${USER_NAME}/.zsh/zsh-syntax-highlighting \
    && git clone https://github.com/zsh-users/zsh-history-substring-search /home/${USER_NAME}/.zsh/zsh-history-substring-search \
    && git clone https://github.com/zsh-users/zsh-completions /home/${USER_NAME}/.zsh/zsh-completions

# ── zsh config ────────────────────────────────────────────────────
RUN cat > /home/${USER_NAME}/.zshrc <<'ZSHRC'
export GOPATH="${HOME}/go"
export PATH="${GOPATH}/bin:${HOME}/.local/bin:${PATH}"
export PIP_BREAK_SYSTEM_PACKAGES=1

alias ll='ls -alF'
alias la='ls -A'

# History
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt SHARE_HISTORY
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_SPACE
setopt HIST_FIND_NO_DUPS
setopt APPEND_HISTORY

# Completions
fpath=(~/.zsh/zsh-completions/src $fpath)
autoload -Uz compinit && compinit
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'

# Plugins
source ~/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh
source ~/.zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
source ~/.zsh/zsh-history-substring-search/zsh-history-substring-search.zsh

# Key bindings for history substring search (up/down arrows)
bindkey '^[[A' history-substring-search-up
bindkey '^[[B' history-substring-search-down

# Starship prompt
eval "$(starship init zsh)"
ZSHRC

# ── bash fallback ─────────────────────────────────────────────────
RUN cat >> /home/${USER_NAME}/.bashrc <<'BASHRC'

export GOPATH="${HOME}/go"
export PATH="${GOPATH}/bin:${HOME}/.local/bin:${PATH}"
export PIP_BREAK_SYSTEM_PACKAGES=1

alias ll='ls -alF'
alias la='ls -A'

eval "$(starship init bash)"
BASHRC

WORKDIR /home/${USER_NAME}/project

ENTRYPOINT ["/home/coder/entrypoint.sh"]
CMD ["zsh"]
