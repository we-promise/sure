# Multi-stage Dockerfile for Flutter Android development
# Inspired by: https://github.com/wtfzambo/flutter-devcontainer-template

# --- Builder Stage ---
FROM --platform=linux/amd64 debian:bookworm-slim AS builder

ARG DEBIAN_FRONTEND=noninteractive

ENV ANDROID_SDK_ROOT=/android-sdk
ENV FLUTTER_SDK_ROOT=/flutter

RUN apt-get update \
  && apt-get -y install --no-install-recommends \
    wget \
    unzip \
    xz-utils \
    openjdk-17-jdk \
  && apt-get autoremove -y \
  && apt-get clean -y \
  && rm -rf /var/lib/apt/lists/*

# Download and install Android Command Line Tools
RUN mkdir -p ${ANDROID_SDK_ROOT}/cmdline-tools \
  && wget -O commandlinetools.zip "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" \
  && unzip commandlinetools.zip -d ${ANDROID_SDK_ROOT}/cmdline-tools \
  && mv ${ANDROID_SDK_ROOT}/cmdline-tools/cmdline-tools ${ANDROID_SDK_ROOT}/cmdline-tools/latest \
  && rm commandlinetools.zip

# Accept Android SDK licenses and install necessary components
# compileSdk=36, minSdkVersion=24 per mobile/android/app/build.gradle
RUN yes | ${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager --licenses && \
  ${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager \
    "build-tools;34.0.0" \
    "platform-tools" \
    "platforms;android-36"

# Download and install Flutter (>=3.27.0 per mobile/pubspec.yaml)
RUN mkdir -p ${FLUTTER_SDK_ROOT} \
  && wget -O flutter.tar.xz "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.29.2-stable.tar.xz" \
  && tar xf flutter.tar.xz -C ${FLUTTER_SDK_ROOT} --strip-components=1 \
  && rm flutter.tar.xz

# --- Final Stage ---
FROM --platform=linux/amd64 debian:bookworm-slim AS final

ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=$USER_UID
ARG HOME=/home/${USERNAME}

ENV ANDROID_SDK_ROOT=${HOME}/android-sdk
ENV FLUTTER_SDK_ROOT=${HOME}/flutter
ENV PATH=$PATH:${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin
ENV PATH=$PATH:${ANDROID_SDK_ROOT}/platform-tools
ENV PATH=$PATH:${FLUTTER_SDK_ROOT}/bin

RUN dpkg --add-architecture amd64 \
  && apt-get update \
  && apt-get -y install --no-install-recommends \
    curl \
    git \
    unzip \
    xz-utils \
    zip \
    openjdk-17-jdk \
    libglu1-mesa \
    libc6:amd64 \
    sudo \
  && apt-get autoremove -y \
  && apt-get clean -y \
  && rm -rf /var/lib/apt/lists/*

# Create a non-root user
RUN groupadd --gid ${USER_GID} ${USERNAME} \
  && useradd --uid ${USER_UID} --gid ${USER_GID} -m ${USERNAME} \
  && echo ${USERNAME} ALL=\(root\) NOPASSWD:ALL > /etc/sudoers.d/${USERNAME} \
  && chmod 0440 /etc/sudoers.d/${USERNAME}

USER ${USERNAME}

# Copy SDKs from the builder stage to the user's home directory
COPY --from=builder --chown=${USERNAME}:${USERNAME} /android-sdk ${ANDROID_SDK_ROOT}
COPY --from=builder --chown=${USERNAME}:${USERNAME} /flutter ${FLUTTER_SDK_ROOT}
