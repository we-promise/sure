ARG RUBY_VERSION=3.4.7
FROM ruby:${RUBY_VERSION}-slim-bookworm

ENV DEBIAN_FRONTEND=noninteractive
ENV FLUTTER_HOME=/opt/flutter
ENV PATH="${FLUTTER_HOME}/bin:${PATH}"

RUN apt-get update -qq \
  && apt-get -y install --no-install-recommends \
    apt-utils \
    build-essential \
    clang \
    cmake \
    curl \
    git \
    imagemagick \
    iproute2 \
    libgtk-3-dev \
    liblzma-dev \
    libpq-dev \
    libyaml-dev \
    libyaml-0-2 \
    ninja-build \
    openssh-client \
    openjdk-17-jdk \
    pkg-config \
    postgresql-client \
    vim \
    procps \
    unzip \
    xz-utils \
    zip \
  && rm -rf /var/lib/apt/lists /var/cache/apt/archives

RUN gem install bundler foreman
RUN gem install cocoapods

# Create a non-root user for devcontainer usage
RUN groupadd -g 1000 dev \
  && useradd -m -u 1000 -g dev -s /bin/bash dev \
  && mkdir -p /bundle /home/dev/.pub-cache \
  && chown -R dev:dev /bundle /home/dev

# Install Node.js 20
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
  && apt-get install -y nodejs \
  && rm -rf /var/lib/apt/lists /var/cache/apt/archives

ARG FLUTTER_VERSION=3.38.7
RUN curl -fsSL "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
  | tar -xJ -C /opt

WORKDIR /workspace
