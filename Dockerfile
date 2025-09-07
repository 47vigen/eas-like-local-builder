# Dynamic LTS/Stable Dev Image for EAS Android builds
FROM ubuntu:jammy

# Use bash for RUN lines
SHELL ["/bin/bash", "-lc"]

# Non-interactive apt
ENV DEBIAN_FRONTEND=noninteractive

# ---------- Base deps ----------
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    unzip \
    xz-utils \
    build-essential \
    python3 \
    python3-pip \
    git \
    jq \
    software-properties-common \
 && rm -rf /var/lib/apt/lists/*

# Pull latest stable Git from PPA (dynamic at build time)
RUN add-apt-repository -y ppa:git-core/ppa \
 && apt-get update && apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/*

# ---------- Java: latest LTS from Adoptium (Temurin) ----------
# We query the official Adoptium API to detect the newest LTS major,
# then fetch the latest GA build for linux/x64, extract and set JAVA_HOME.
ENV JAVA_HOME=/usr/lib/jvm/temurin-lts
ENV PATH="$JAVA_HOME/bin:${PATH}"
RUN set -euxo pipefail; \
    LTS_MAJOR="$(curl -fsSL https://api.adoptium.net/v3/info/available_releases | jq -r '.available_lts_releases[-1]')" ; \
    curl -fsSL "https://api.adoptium.net/v3/binary/latest/${LTS_MAJOR}/ga/linux/x64/jdk/hotspot/normal/eclipse?project=jdk" \
      -o /tmp/temurin.tar.gz; \
    mkdir -p /usr/lib/jvm/temurin; \
    tar -xzf /tmp/temurin.tar.gz -C /usr/lib/jvm/temurin --strip-components=1; \
    rm /tmp/temurin.tar.gz; \
    ln -sfn /usr/lib/jvm/temurin "$JAVA_HOME"; \
    java -version

# ---------- Node.js LTS (dynamic) + package managers ----------
# We parse Node's official index.json to grab the newest LTS, download, and install.
RUN set -euxo pipefail; \
    NODE_VERSION="$(curl -fsSL https://nodejs.org/dist/index.json | jq -r '[.[] | select(.lts != false)][0].version')" ; \
    NODE_TAR="node-${NODE_VERSION}-linux-x64.tar.xz"; \
    curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/${NODE_TAR}" -o "/tmp/${NODE_TAR}"; \
    tar -xJf "/tmp/${NODE_TAR}" -C /usr/local --strip-components=1; \
    rm "/tmp/${NODE_TAR}"; \
    node -v && npm -v

# Use Corepack to get the latest stable Yarn/Pnpm at build time
RUN corepack enable \
 && corepack prepare yarn@stable --activate \
 && corepack prepare pnpm@latest --activate

# Upgrade npm to latest stable, install latest node-gyp & eas-cli
RUN npm i -g npm@latest \
 && npm i -g node-gyp@latest eas-cli@latest

# ---------- Bun (latest stable) ----------
ENV BUN_INSTALL=/usr/local
ENV PATH="${BUN_INSTALL}/bin:${PATH}"
RUN curl -fsSL https://bun.sh/install | bash \
 && bun --version

# ---------- Android SDK / NDK (dynamic latest) ----------
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV ANDROID_HOME=/opt/android-sdk
ENV PATH="${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${PATH}"

# Commandline tools (always the _latest zip)
RUN set -euxo pipefail; \
    mkdir -p "${ANDROID_SDK_ROOT}/cmdline-tools"; \
    curl -fsSL "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" -o /tmp/clt.zip || \
    curl -fsSL "https://dl.google.com/android/repository/commandlinetools-linux-9477386_latest.zip" -o /tmp/clt.zip || \
    curl -fsSL "https://dl.google.com/android/repository/commandlinetools-linux-7583922_latest.zip" -o /tmp/clt.zip; \
    unzip -q /tmp/clt.zip -d "${ANDROID_SDK_ROOT}/cmdline-tools"; \
    mv "${ANDROID_SDK_ROOT}/cmdline-tools/cmdline-tools" "${ANDROID_SDK_ROOT}/cmdline-tools/latest"; \
    rm /tmp/clt.zip

# Accept licenses, install platform-tools, then auto-detect newest Platform / Build-Tools / NDK from the official repo list
RUN set -euxo pipefail; \
    yes | sdkmanager --licenses >/dev/null; \
    sdkmanager "platform-tools"; \
    # Parse latest android platform level
    LATEST_PLATFORM="$(sdkmanager --list | sed -n 's/.*platforms;android-\([0-9][0-9]*\).*/\1/p' | sort -n | tail -1)"; \
    # Parse latest build-tools full version
    LATEST_BUILD_TOOLS="$(sdkmanager --list | sed -n 's/.*build-tools;\([0-9][0-9.]*\).*/\1/p' | sort -V | tail -1)"; \
    # Parse latest NDK version
    LATEST_NDK="$(sdkmanager --list | sed -n 's/.*ndk;\([0-9][0-9.]*\).*/\1/p' | sort -V | tail -1)"; \
    echo "Latest Android Platform: ${LATEST_PLATFORM}"; \
    echo "Latest Build-Tools: ${LATEST_BUILD_TOOLS}"; \
    echo "Latest NDK: ${LATEST_NDK}"; \
    sdkmanager "platforms;android-${LATEST_PLATFORM}" "build-tools;${LATEST_BUILD_TOOLS}" "ndk;${LATEST_NDK}"; \
    # Symlink a stable NDK_HOME to the chosen NDK version for downstream tools
    ln -sfn "${ANDROID_SDK_ROOT}/ndk/${LATEST_NDK}" /opt/android-ndk; \
    echo "ndk.dir=/opt/android-ndk" > /opt/local.properties

ENV NDK_HOME=/opt/android-ndk

# ---------- Cleanup ----------
RUN rm -rf /var/lib/apt/lists/* /root/.cache/*

# ---------- Default EAS command ----------
# PROFILE can be overridden at runtime: `-e PROFILE=production`
ENV PROFILE=development
CMD ["bash", "-lc", "eas build --platform android --local --profile ${PROFILE}"]
