FROM debian:bookworm-slim

LABEL org.opencontainers.image.title="satisfactory-docker" \
      org.opencontainers.image.description="Satisfactory Dedicated Server with auto-updates, persistent saves, and .smmprofile mod support" \
      org.opencontainers.image.source="https://github.com/satisfactorymodding/ficsit-cli"

ARG DEBIAN_FRONTEND=noninteractive
ARG FICSIT_CLI_VERSION=latest

ENV HOME=/home/steam \
    STEAMCMD_DIR=/opt/steamcmd \
    SERVER_DIR=/config/gamefiles \
    SAVES_DIR=/config/saves \
    SAVED_DIR=/config/saved \
    MODS_PROFILE_PATH=/config/mods.smmprofile \
    FICSIT_LOCAL_DIR=/config/ficsit/local \
    FICSIT_CACHE_DIR=/config/ficsit/cache \
    PUID=1000 \
    PGID=1000 \
    GAME_PORT=7777 \
    RELIABLE_PORT=8888 \
    EXTERNAL_RELIABLE_PORT= \
    MULTIHOME=0.0.0.0 \
    MAX_PLAYERS= \
    AUTO_UPDATE=true \
    VALIDATE_INSTALL=false \
    STEAM_BETA=public \
    STEAM_BETA_PASSWORD= \
    MODS_ENABLED=true \
    EXTRA_SERVER_ARGS=

# Install 32-bit SteamCMD dependencies, Unreal runtime helpers, and mod tooling
RUN dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gosu \
        jq \
        lib32gcc-s1 \
        lib32stdc++6 \
        procps \
        tar \
        unzip \
        xdg-user-dirs \
    && rm -rf /var/lib/apt/lists/*

# Create non-root steam user
RUN groupadd -g 1000 steam \
    && useradd -m -u 1000 -g 1000 -s /bin/bash steam

# Install SteamCMD (game files are pulled at runtime into /config/gamefiles)
RUN mkdir -p "${STEAMCMD_DIR}" \
    && curl -fsSL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" \
       | tar -xz -C "${STEAMCMD_DIR}" \
    && chown -R steam:steam "${STEAMCMD_DIR}"

# Install ficsit-cli for Linux dedicated server mod management
RUN if [ "${FICSIT_CLI_VERSION}" = "latest" ]; then \
        FICSIT_URL="https://github.com/satisfactorymodding/ficsit-cli/releases/latest/download/ficsit_linux_amd64"; \
    else \
        FICSIT_URL="https://github.com/satisfactorymodding/ficsit-cli/releases/download/${FICSIT_CLI_VERSION}/ficsit_linux_amd64"; \
    fi \
    && curl -fsSL -o /usr/local/bin/ficsit "${FICSIT_URL}" \
    && chmod 0755 /usr/local/bin/ficsit

COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/sync-mods.sh /usr/local/bin/sync-mods.sh
COPY scripts/healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/sync-mods.sh /usr/local/bin/healthcheck.sh

RUN mkdir -p "${SERVER_DIR}" "${SAVES_DIR}" "${SAVED_DIR}" "${FICSIT_LOCAL_DIR}" "${FICSIT_CACHE_DIR}" \
    && chown -R steam:steam /config

EXPOSE 7777/udp 7777/tcp 8888/tcp

WORKDIR /config/gamefiles

HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
