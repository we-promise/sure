ARG RUBY_VERSION=3.4.9
FROM ruby:${RUBY_VERSION}-slim-bookworm

ENV DEBIAN_FRONTEND=noninteractive

# libvips42 supports ActiveStorage image variants through image_processing/ruby-vips
# for existing profile/avatar images. AccountStatement.original_file only stores
# PDF/CSV/XLSX originals, but the devcontainer needs this broader image stack.
# poppler-utils provides pdftoppm, required for the PDF vision processing path.
RUN apt-get update -qq \
  && apt-get -y install --no-install-recommends \
    apt-utils \
    build-essential \
    curl \
    git \
    imagemagick \
    iproute2 \
    libvips42 \
    libpq-dev \
    libyaml-dev \
    libyaml-0-2 \
    openssh-client \
    postgresql-client \
    poppler-utils \
    procps \
    vim \
  && rm -rf /var/lib/apt/lists /var/cache/apt/archives

RUN gem install bundler foreman

# The Codex subscription flow is opt-in. Local development enables this build
# argument so the Settings UI can launch `codex login --device-auth`; production
# deployments can install the CLI separately and set CODEX_COMMAND.
ARG INSTALL_CODEX=false
RUN if [ "$INSTALL_CODEX" = "true" ]; then \
      curl -fsSL https://chatgpt.com/codex/install.sh | sh; \
    fi
ENV PATH="/root/.local/bin:${PATH}"

# Install Node.js 20
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
  && apt-get install -y nodejs \
  && rm -rf /var/lib/apt/lists /var/cache/apt/archives

WORKDIR /workspace
