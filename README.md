# satisfactory-docker

Dockerized **Satisfactory Dedicated Server** built on `debian:bookworm-slim` with:

- **Automatic SteamCMD updates** — checks Steam (App ID `1690800`) on container start/restart and downloads updates only when needed
- **Persistent saves & server state** — maps `./saves` directly to Unreal's `SaveGames` directory and persists game files, INI configs, and server state in `./data`
- **Auto-restarts & graceful shutdown** — uses `restart: unless-stopped` and forwards `SIGTERM` with a `90s` grace period so the world saves cleanly
- **Configurable ports** — configure `GAME_PORT`, `RELIABLE_PORT`, and optional `EXTERNAL_RELIABLE_PORT` in `.env`
- **Mod Manager profile support (`mods.smmprofile`)** — drop your exported `.smmprofile` next to `docker-compose.yaml` and `ficsit-cli` automatically resolves and installs SML and server-compatible mods

> **Architecture note:** Satisfactory Dedicated Server on Linux is `linux/amd64` only.

## Quick Start

You only need `docker-compose.yaml`, `.env`, and `mods.smmprofile` on your server — `docker compose` pulls the prebuilt image from GitHub Container Registry (`ghcr.io/zyon900/satisfactory-docker:latest`).

1. **Download the runtime files** into a folder on your server (or clone the repo):
   ```bash
   mkdir -p satisfactory && cd satisfactory
   curl -fsSLO https://raw.githubusercontent.com/Zyon900/satisfactory-docker/main/docker-compose.yaml
   curl -fsSLO https://raw.githubusercontent.com/Zyon900/satisfactory-docker/main/.env
   curl -fsSLO https://raw.githubusercontent.com/Zyon900/satisfactory-docker/main/mods.smmprofile
   ```
2. **(Optional) Configure ports & settings** in [`.env`](./.env):
   ```dotenv
   GAME_PORT=7777
   RELIABLE_PORT=8888
   ```
3. **(Optional) Add mods** by replacing [`mods.smmprofile`](./mods.smmprofile) with your exported profile from Satisfactory Mod Manager (or point `MODS_PROFILE_FILE` in `.env` to another path).
4. **Start the server**:
   ```bash
   docker compose up -d
   ```
5. **Follow startup logs** (the first launch downloads the dedicated server via SteamCMD):
   ```bash
   docker compose logs -f
   ```

> To build locally from source instead of pulling from GHCR, clone the repo and run `docker build -t ghcr.io/zyon900/satisfactory-docker:latest .`.

## Configuration (`.env`)

| Variable | Default | Description |
| --- | --- | --- |
| `GAME_PORT` | `7777` | Primary game & HTTPS API port (`UDP` + `TCP`). Must match between host and container. |
| `RELIABLE_PORT` | `8888` | Reliable messaging port (`TCP`, required since Satisfactory 1.1). |
| `EXTERNAL_RELIABLE_PORT` | *(empty)* | Optional external port reported to clients if behind NAT port remapping. |
| `MULTIHOME` | `0.0.0.0` | IP interface to bind inside the container. |
| `MAX_PLAYERS` | *(empty)* | Optional player cap override (`-ini:Game:[/Script/Engine.GameSession]:MaxPlayers=...`). |
| `AUTO_UPDATE` | `true` | Checks SteamCMD for dedicated server updates on every container start/restart. |
| `VALIDATE_INSTALL` | `false` | Forces `validate` on every SteamCMD check (first install always validates). |
| `STEAM_BETA` | `public` | Steam branch (`public` or `experimental`). |
| `STEAM_BETA_PASSWORD` | *(empty)* | Optional Steam beta branch password. |
| `MODS_PROFILE_FILE` | `./mods.smmprofile` | Path to your `.smmprofile` file relative to `docker-compose.yaml` (or absolute). |
| `MODS_ENABLED` | `true` | Set to `false` to disable all mods and restore vanilla mode without removing `mods.smmprofile`. |
| `PUID` / `PGID` | `1000` / `1000` | Host UID/GID used for ownership of `./saves` and `./data`. |
| `EXTRA_SERVER_ARGS` | *(empty)* | Extra flags appended to `FactoryServer.sh`. |

### Firewall / Router Port Forwarding

Forward and allow both ports on your host firewall and router:
- `7777/udp` and `7777/tcp` (or your configured `GAME_PORT`)
- `8888/tcp` (or your configured `RELIABLE_PORT`)

## Persistence Layout

| Host Path | Container Path | Purpose |
| --- | --- | --- |
| `./saves` | `/config/saves` | World `.sav` files (`./saves/server/`) and `ServerSettings.<port>.sav` |
| `./data/gamefiles` | `/config/gamefiles` | Dedicated server installation, `FactoryGame/Saved/Config/LinuxServer/*.ini`, and installed mods |
| `./data/saved` | `/config/saved` | Unreal `Saved` state (certificates, ServerManager data, logs) |
| `./data/ficsit` | `/config/ficsit` | `ficsit-cli` mod download cache and local registry |
| `./mods.smmprofile` | `/config/mods.smmprofile` | Satisfactory Mod Manager profile (read-only mount) |

## Mod Support (`mods.smmprofile`)

1. In **Satisfactory Mod Manager**, export your mod profile (`Export Profile` -> saves a `.smmprofile` file).
2. Save or overwrite `./mods.smmprofile` in the same directory as `docker-compose.yaml` (or set `MODS_PROFILE_FILE` in `.env`).
3. Start or restart the container (`docker compose restart`).

On startup, `sync-mods.sh` parses `mods.smmprofile` (supporting SMM3 `.smmprofile` JSON with optional lockfile, bare `{ "mods": ... }` JSON, and legacy SMM2 `.smmprofile` zip archives), configures `ficsit-cli`, installs SML and all enabled `LinuxServer`-compatible mods, and skips client-only mods automatically. Leaving `mods.smmprofile` empty (the default) or setting `MODS_ENABLED=false` cleans up mods and runs vanilla.

## Testing

Run the local script syntax and mod-sync unit tests:

```bash
bash tests/test_sync_mods.sh
```
