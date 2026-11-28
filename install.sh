#!/usr/bin/env bash
# Amphora one-line installer.
#
#   curl -fsSL https://get.amphoracdn.com/install.sh | bash -s <INSTALL CODE>
#
# The install code comes from BrandBox. It carries the license key (which is
# also the login for registry.amphoracdn.com, where updates come from) and
# the image name — nothing to type or paste afterwards.
# What this does, in order: checks Docker (installs it on Linux if asked),
# writes ~/amphora/{docker-compose.yml,.env,amphora.env}, logs in to the
# registry, starts Amphora plus its updater, waits until it answers, and
# prints the address to open.
#
# Running it again with a new code on an existing install moves that install
# to the code's registry and license and to the newest version, keeping its
# data (the amphora-data volume) and its own settings: amphora.env and .env
# only have the license, registry and updater lines changed, the port is
# kept, and the three files are copied to ~/amphora/backup-<time>/ first.
# Amphora is offline for the usual restart, about a minute.
#
#   bash install.sh update      # pull the newest version and restart
#   bash install.sh use 1.47.1  # switch to a given version (going back)
#   bash install.sh status      # show the containers
set -euo pipefail

DIR="${AMPHORA_HOME:-$HOME/amphora}"
BACKUP=""
PORT="${AMPHORA_PORT:-3000}"
say()  { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
die()  { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

need_docker() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then ok "Docker is installed and running"; return; fi
  case "$(uname -s)" in
    Linux)
      say "Docker isn't installed. Installing it with Docker's official script (needs sudo)."
      curl -fsSL https://get.docker.com | sh
      sudo usermod -aG docker "$USER" 2>/dev/null || true
      docker info >/dev/null 2>&1 || sudo systemctl start docker
      docker info >/dev/null 2>&1 || die "Docker installed but this shell can't reach it yet. Log out and back in (or run: newgrp docker), then run the installer again."
      ok "Docker installed";;
    Darwin)
      die "Install Docker Desktop first (https://www.docker.com/products/docker-desktop/), open it once, then run this again.";;
    *) die "Install Docker for this system first, then run this again.";;
  esac
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is missing (docker compose). Update Docker and try again."
}

decode_code() {
  local code="$1"
  [[ "$code" == AMPHINST1.* ]] || die "That doesn't look like an Amphora install code (it starts with AMPHINST1.)."
  local b64="${code#AMPHINST1.}"
  b64="$(printf '%s' "$b64" | tr '_-' '/+')"
  while (( ${#b64} % 4 )); do b64="${b64}="; done
  printf '%s' "$b64" | base64 -d 2>/dev/null || printf '%s' "$b64" | base64 --decode
}

# The compose file. Amphora's own updater (docker/updater.mjs in the image,
# 1.48+) can switch versions both ways — Update to … and Go back to … — and
# pins the version in .env (AMPHORA_TAG). Images before 1.48 don't carry it,
# so then the updater is Watchtower, which can only update.
write_compose() {
  local image; image="$(sed -n 's/^AMPHORA_IMAGE=//p' "$DIR/.env" | head -1)"
  local own=0
  if [[ -n "$image" ]] && docker pull -q "$image:latest" >/dev/null 2>&1 && docker run --rm --entrypoint test "$image:latest" -f docker/updater.mjs 2>/dev/null; then own=1; fi
  grep -q '^AMPHORA_TAG=' "$DIR/.env" 2>/dev/null || printf 'AMPHORA_TAG=latest\n' >> "$DIR/.env"
  cat > "$DIR/docker-compose.yml" <<'YML'
# Written by the Amphora installer. Update or go back from inside Amphora
# (Settings → General → Updates) or: install.sh update | install.sh use <version>
services:
  amphora:
    image: ${AMPHORA_IMAGE}:${AMPHORA_TAG:-latest}
    container_name: amphora
    restart: unless-stopped
    ports:
      - "${AMPHORA_PORT:-3000}:3000"
      # Worlds (demo, rehearsal databases) each run on their own port.
      - "3101-3110:3101-3110"
    volumes:
      - amphora-data:/data
    env_file:
      - amphora.env
    labels:
      - "com.centurylinklabs.watchtower.enable=true"
YML
  if (( own )); then
    cat >> "$DIR/docker-compose.yml" <<'YML'
  # Amphora's updater: acts only when Amphora asks; switches the amphora
  # container to the asked-for version, puts the old one back if the new one
  # doesn't start, and pins the version in .env.
  updater:
    image: ${AMPHORA_IMAGE}:latest
    container_name: amphora-updater
    restart: unless-stopped
    user: root
    command: ["node", "docker/updater.mjs"]
    healthcheck:
      disable: true
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./:/install
    environment:
      AMPHORA_UPDATER_TOKEN: ${AMPHORA_UPDATER_TOKEN}
      AMPHORA_TARGET: amphora
      REPO_USER: ${REGISTRY_USER}
      REPO_PASS: ${REGISTRY_TOKEN}
YML
  else
    cat >> "$DIR/docker-compose.yml" <<'YML'
  updater:
    image: containrrr/watchtower:1.7.1
    container_name: amphora-updater
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      WATCHTOWER_HTTP_API_UPDATE: "true"
      WATCHTOWER_HTTP_API_TOKEN: ${AMPHORA_UPDATER_TOKEN}
      WATCHTOWER_LABEL_ENABLE: "true"
      WATCHTOWER_CLEANUP: "true"
      WATCHTOWER_NO_STARTUP_MESSAGE: "true"
      # Watchtower 1.7.1 speaks Docker API 1.25; daemons since Docker 25
      # refuse anything below 1.40. Pin the client version it announces.
      DOCKER_API_VERSION: "1.44"
      REPO_USER: ${REGISTRY_USER}
      REPO_PASS: ${REGISTRY_TOKEN}
YML
  fi
  cat >> "$DIR/docker-compose.yml" <<'YML'
volumes:
  amphora-data:
YML
}

set_tag() { # AMPHORA_TAG=<tag> in .env
  local rest; rest="$(grep -v '^AMPHORA_TAG=' "$DIR/.env")"
  umask 077; printf '%s\nAMPHORA_TAG=%s\n' "$rest" "$1" > "$DIR/.env"
}

# KEY=value in a file: replace the line or add it, keep every other line.
set_kv() {
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp "$DIR/.kv.XXXXXX")"
  { grep -v "^$key=" "$file" 2>/dev/null || true; printf '%s=%s\n' "$key" "$value"; } > "$tmp"
  chmod 600 "$tmp"; mv "$tmp" "$file"
}
get_kv() { [[ -f "$1" ]] || return 0; sed -n "s/^$2=//p" "$1" | tail -1; }

# Sign in to the install's registry with the login in .env (none = open registry).
registry_login() {
  local image user token registry
  image="$(get_kv "$DIR/.env" AMPHORA_IMAGE)"; user="$(get_kv "$DIR/.env" REGISTRY_USER)"; token="$(get_kv "$DIR/.env" REGISTRY_TOKEN)"
  [[ -n "$token" ]] || return 0
  registry="${image%%/*}"
  [[ "$registry" == *.* || "$registry" == *:* ]] || registry="ghcr.io"
  printf '%s' "$token" | docker login "$registry" -u "$user" --password-stdin >/dev/null 2>&1 && ok "Signed in to $registry" \
    || die "Couldn't sign in to $registry. The license may have expired or been replaced: paste the current key under Settings → General, or ask BrandBox for a fresh install code."
}

write_files() {
  mkdir -p "$DIR"; chmod 700 "$DIR"
  local decoded; decoded="$(decode_code "$1")"
  # The code is KEY=VALUE lines. Pull out what compose needs vs what the app needs.
  local get; get() { printf '%s\n' "$decoded" | sed -n "s/^$1=//p" | head -1; }
  local image user token key
  image="$(get AMPHORA_IMAGE)"; user="$(get REGISTRY_USER)"; token="$(get REGISTRY_TOKEN)"; key="$(get AMPHORA_LICENSE_KEY)"
  [[ -n "$image" && -n "$user" && -n "$token" ]] || die "The install code is missing the registry login. Ask BrandBox for a fresh one."
  # A token of "none" means an open registry (local testing) — no login, no creds.
  if [[ "$token" == "none" ]]; then user=""; token=""; fi

  local existing=0
  [[ -f "$DIR/.env" ]] && existing=1
  if (( existing )); then
    BACKUP="$DIR/backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP"; chmod 700 "$BACKUP"
    for f in .env amphora.env docker-compose.yml; do if [[ -f "$DIR/$f" ]]; then cp -p "$DIR/$f" "$BACKUP/$f"; fi; done
    ok "Saved the current settings to $BACKUP"
  fi

  umask 077
  local updater_token port
  updater_token="$(get_kv "$DIR/.env" AMPHORA_UPDATER_TOKEN)"
  [[ -n "$updater_token" ]] || updater_token="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 40)"
  port="$(get_kv "$DIR/.env" AMPHORA_PORT)"; port="${port:-$PORT}"; PORT="$port"
  touch "$DIR/.env"
  set_kv "$DIR/.env" AMPHORA_IMAGE "$image"
  set_kv "$DIR/.env" AMPHORA_PORT "$port"
  set_kv "$DIR/.env" REGISTRY_USER "$user"
  set_kv "$DIR/.env" REGISTRY_TOKEN "$token"
  set_kv "$DIR/.env" AMPHORA_UPDATER_TOKEN "$updater_token"
  # A new code means the newest version: it's the one that accepts the code's license.
  set_kv "$DIR/.env" AMPHORA_TAG latest

  if [[ -f "$DIR/amphora.env" ]]; then
    # The install's own settings (web address, proxies, workers…) stay as they are.
    if [[ -n "$key" ]]; then set_kv "$DIR/amphora.env" AMPHORA_LICENSE_KEY "$key"; fi
    set_kv "$DIR/amphora.env" AMPHORA_UPDATER_URL "http://updater:8080/v1/update"
    set_kv "$DIR/amphora.env" AMPHORA_UPDATER_TOKEN "$updater_token"
  else
    cat > "$DIR/amphora.env" <<ENV
AMPHORA_LICENSE_KEY=$key
AMPHORA_ALLOW_INSECURE_HTTP=1
AMPHORA_UPDATE_CHECK=1
AMPHORA_UPDATER_URL=http://updater:8080/v1/update
AMPHORA_UPDATER_TOKEN=$updater_token
ENV
  fi
  registry_login
  write_compose
  ok "Wrote $DIR/docker-compose.yml, .env, amphora.env"
  if (( existing )) && [[ -f "$BACKUP/docker-compose.yml" ]] && ! cmp -s "$BACKUP/docker-compose.yml" "$DIR/docker-compose.yml"; then
    printf '  ! docker-compose.yml was rewritten. If it had changes of your own, they are in %s/docker-compose.yml.\n' "$BACKUP"
  fi
}

wait_ready() {
  printf '  waiting for Amphora'
  for _ in $(seq 1 90); do
    if curl -fsS "http://127.0.0.1:$PORT/login" >/dev/null 2>&1; then printf '\n'; return 0; fi
    printf '.'; sleep 2
  done
  printf '\n'; return 1
}

lan_ip() {
  local ip
  ip="$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || true)"
  printf '%s' "${ip:-localhost}"
}

# Everything runs from main so the whole script is parsed before anything
# executes — required when it arrives through "curl | bash -s", where a
# command reading stdin would otherwise eat the rest of the script.
main() {
cmd="${1:-}"
case "$cmd" in
  update)
    cd "$DIR" 2>/dev/null || die "No install at $DIR."
    say "Pulling the newest Amphora"; registry_login; set_tag latest; write_compose
    docker compose pull; docker compose up -d --remove-orphans
    wait_ready && ok "Updated. Open http://$(lan_ip):$PORT" ;;
  use)
    # Any published version, e.g. going back: install.sh use 1.47.1
    cd "$DIR" 2>/dev/null || die "No install at $DIR."
    ver="${2:-}"; ver="${ver#v}"
    [[ "$ver" =~ ^([0-9]+\.[0-9]+\.[0-9]+|latest)$ ]] || die "Usage: install.sh use <version>   (e.g. install.sh use 1.47.1, or latest)"
    say "Switching Amphora to $ver"; registry_login; set_tag "$ver"
    docker compose pull amphora || die "Couldn't download version $ver."
    docker compose up -d amphora
    wait_ready && ok "Amphora is on $ver. Open http://$(lan_ip):$PORT" ;;
  status)
    cd "$DIR" 2>/dev/null || die "No install at $DIR."; docker compose ps ;;
  "")
    die "Usage: install.sh <INSTALL CODE>   (or: install.sh update | use <version> | status)" ;;
  *)
    say "Checking Docker"; need_docker
    was_installed=0; [[ -f "$DIR/.env" ]] && was_installed=1
    say "Writing the install to $DIR"; write_files "$cmd"
    # Download first, then restart: Amphora is only offline for the restart itself.
    say "Downloading Amphora"; (cd "$DIR" && docker compose pull --quiet) || die "Couldn't download Amphora. Nothing was restarted; your settings are unchanged apart from the files above (copies in ${BACKUP:-$DIR})."
    say "Starting Amphora"; (cd "$DIR" && docker compose up -d --remove-orphans 2>&1 | grep -v '^$' || true)
    if wait_ready; then
      ok "Amphora is running"
      if (( was_installed )); then
        printf '\n\033[1mDone.\033[0m Amphora is on the newest version with the new license; data and settings are unchanged.\n'
        printf 'Check Settings → General (License and Updates) at http://%s:%s. Previous settings: %s\n\n' "$(lan_ip)" "$PORT" "$BACKUP"
      else
        printf '\n\033[1mOpen http://%s:%s\033[0m and create the owner account.\n' "$(lan_ip)" "$PORT"
        printf 'The license is already activated. Phones and scanners on the same network use the same address.\n'
        printf 'Updates: Settings → General → Update. Back up the amphora-data Docker volume.\n\n'
      fi
    else
      die "Amphora started but isn't answering on port $PORT yet. Check: cd $DIR && docker compose logs amphora"
    fi ;;
esac
}

main "$@" </dev/null
