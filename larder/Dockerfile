# syntax=docker/dockerfile:1
#
# Larder workspace: Debian + Nix + the pi coding agent. Used by Larder's
# setup.ps1, its VS Code devcontainer and its CI.
#
# larder/flake.nix and flake.lock are copies of the ones in the Larder repo,
# used only to pre-fetch the toolchain. At runtime the workspace's own flake
# is used, so a stale copy just means a slower first shell.

FROM nixos/nix:2.35.4 AS nix

FROM debian:trixie-slim

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y ca-certificates procps less && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY --from=nix /nix /nix

ENV PATH="/root/.nix-profile/bin:/nix/var/nix/profiles/default/bin:${PATH}" \
    NIX_SSL_CERT_FILE="/etc/ssl/certs/ca-certificates.crt" \
    LARDER_ROOT="/workspace"

# Single-user Nix as root; containers can't use the build sandbox.
RUN mkdir -p /etc/nix && printf '%s\n' \
      'build-users-group =' \
      'sandbox = false' \
      'experimental-features = nix-command flakes' \
      > /etc/nix/nix.conf

# Pre-fetch the toolchain. The nixpkgs source is kept as a GC root so dev
# shells evaluate offline.
COPY larder/flake.nix larder/flake.lock /opt/larder-flake/
RUN nix develop /opt/larder-flake --profile /nix/var/nix/profiles/larder-dev --command true && \
    ln -s "$(nix eval --raw --impure --expr '(builtins.getFlake "path:/opt/larder-flake").inputs.nixpkgs.outPath')" \
      /nix/var/nix/gcroots/larder-nixpkgs && \
    nix-collect-garbage

# pi from nixpkgs: prebuilt on cache.nixos.org, so it downloads instead of
# compiling (the upstream github:earendil-works/pi flake has no binary cache).
# GC drops the nixpkgs-unstable source fetched to evaluate it.
RUN nix profile add github:NixOS/nixpkgs/nixos-unstable#pi-coding-agent && nix-collect-garbage

# Load the workspace flake's dev shell into the current bash session. Cached
# per flake.nix + flake.lock, so new shells start fast after the first one.
COPY <<'EOF' /usr/local/lib/larder/env.sh
if [ -z "${IN_NIX_SHELL:-}" ] && [ -f "${LARDER_ROOT}/flake.nix" ]; then
  __larder_key=$(cat "${LARDER_ROOT}/flake.nix" "${LARDER_ROOT}/flake.lock" 2>/dev/null | sha256sum | cut -c1-16)
  __larder_env="${LARDER_ROOT}/tmp/nix/env-${__larder_key}.sh"
  if [ ! -s "$__larder_env" ]; then
    echo "Loading the Nix dev environment (slow the first time)..." >&2
    mkdir -p "${LARDER_ROOT}/tmp/nix"
    nix print-dev-env "${LARDER_ROOT}" > "${__larder_env}.tmp" && mv "${__larder_env}.tmp" "$__larder_env"
  fi
  pushd "${LARDER_ROOT}" > /dev/null && source "$__larder_env" && popd > /dev/null
  unset __larder_key __larder_env
fi
EOF
RUN echo 'source /usr/local/lib/larder/env.sh' >> /etc/bash.bashrc

# `larder-env <command>` runs a command inside the dev shell.
COPY --chmod=755 <<'EOF' /usr/local/bin/larder-env
#!/usr/bin/env bash
source /usr/local/lib/larder/env.sh
exec "$@"
EOF

# `larder-server start|stop|restart|logs [lines]` runs bin/dev in the
# background. Logs go outside the repo: tailwindcss:watch rebuilds on any file
# change under it, including its own log.
COPY --chmod=755 <<'EOF' /usr/local/bin/larder-server
#!/usr/bin/env bash
set -eo pipefail
log=/tmp/larder-server.log

stop() {
  if pkill -f "foreman start" 2>/dev/null; then
    for _ in $(seq 1 20); do pgrep -f "foreman start" > /dev/null || break; sleep 0.5; done
  fi
  rm -f "${LARDER_ROOT}/tmp/pids/server.pid"
}

case "${1:-start}" in
  start|restart)
    stop
    source /usr/local/lib/larder/env.sh
    cd "$LARDER_ROOT"
    BINDING=0.0.0.0 nohup bin/dev > "$log" 2>&1 &
    for _ in $(seq 1 60); do
      if curl -s -o /dev/null http://localhost:3000/; then
        echo "Larder is running at http://localhost:3000 (logs: larder-server logs)"
        exit 0
      fi
      sleep 1
    done
    echo "Server didn't answer within 60s. Last log lines:" >&2
    tail -n 30 "$log" >&2
    exit 1
    ;;
  stop) stop; echo "Stopped." ;;
  logs) tail -n "${2:-100}" "$log" ;;
  *) echo "usage: larder-server start|stop|restart|logs [lines]" >&2; exit 2 ;;
esac
EOF

# `larder`: entry point for the pi workspace (setup.ps1 clones the repo into
# /workspace first). Wires up GitHub auth, sets up the app, starts it, opens pi.
COPY --chmod=755 <<'EOF' /usr/local/bin/larder
#!/usr/bin/env bash
set -eo pipefail
cd "$LARDER_ROOT"
source /usr/local/lib/larder/env.sh

# Use the gh login (persisted in a volume) for git push, and commit as that user.
if gh auth status > /dev/null 2>&1; then
  gh auth setup-git
  if [ -z "$(git config --global user.name)" ]; then
    IFS=$'\t' read -r gh_id gh_login gh_name < <(gh api user --jq '[.id, .login, (.name // .login)] | @tsv')
    git config --global user.name "$gh_name"
    git config --global user.email "${gh_id}+${gh_login}@users.noreply.github.com"
  fi
fi

echo "==> Installing gems and preparing the database"
bin/setup --skip-server

echo "==> Starting the app"
larder-server start || echo "(The app didn't start; ask pi to look at 'larder-server logs'.)"

exec pi "$@"
EOF

WORKDIR /workspace
CMD ["bash"]
