# syntax=docker/dockerfile:1
#
# Nix + the pi coding agent on Debian. For projects that define their toolchain
# in a flake.nix: interactive shells, `devshell <command>`, and anything pi runs
# get the dev shell of the flake in $WORKSPACE (default /workspace).
#
# Debian rather than nixos/nix so VS Code and precompiled binaries (e.g. gems
# that ship executables) work. Projects can extend it to pre-fetch their
# toolchain:
#
#   FROM ghcr.io/temannin/devcontainers-nix-pi:latest
#   COPY flake.nix flake.lock /opt/project-flake/
#   RUN nix develop /opt/project-flake --profile /nix/var/nix/profiles/project --command true

FROM nixos/nix:2.35.4 AS nix

FROM debian:trixie-slim

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y ca-certificates procps less && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY --from=nix /nix /nix

ENV PATH="/root/.nix-profile/bin:/nix/var/nix/profiles/default/bin:${PATH}" \
    NIX_SSL_CERT_FILE="/etc/ssl/certs/ca-certificates.crt" \
    WORKSPACE="/workspace"

# Single-user Nix as root; containers can't use the build sandbox.
RUN mkdir -p /etc/nix && printf '%s\n' \
      'build-users-group =' \
      'sandbox = false' \
      'experimental-features = nix-command flakes' \
      > /etc/nix/nix.conf

# pi from nixpkgs: prebuilt on cache.nixos.org, so it downloads instead of
# compiling (the upstream github:earendil-works/pi flake has no binary cache).
# GC drops the nixpkgs-unstable source fetched to evaluate it.
RUN nix profile add github:NixOS/nixpkgs/nixos-unstable#pi-coding-agent && nix-collect-garbage

# Load the dev shell of $WORKSPACE/flake.nix into the current bash session.
# Cached per flake.nix + flake.lock, so later shells in a container start fast.
COPY <<'EOF' /usr/local/lib/nix-pi/devshell.sh
if [ -z "${IN_NIX_SHELL:-}" ] && [ -f "${WORKSPACE}/flake.nix" ]; then
  __devshell_key=$(cat "${WORKSPACE}/flake.nix" "${WORKSPACE}/flake.lock" 2>/dev/null | sha256sum | cut -c1-16)
  __devshell_env="${XDG_CACHE_HOME:-$HOME/.cache}/nix-pi/env-${__devshell_key}.sh"
  if [ ! -s "$__devshell_env" ]; then
    echo "Loading the Nix dev shell for ${WORKSPACE}..." >&2
    mkdir -p "$(dirname "$__devshell_env")"
    nix print-dev-env "${WORKSPACE}" > "${__devshell_env}.tmp" && mv "${__devshell_env}.tmp" "$__devshell_env"
  fi
  pushd "${WORKSPACE}" > /dev/null && source "$__devshell_env" && popd > /dev/null
  unset __devshell_key __devshell_env
fi
EOF

# `devshell <command>` runs a command inside the workspace's dev shell.
COPY --chmod=755 <<'EOF' /usr/local/bin/devshell
#!/usr/bin/env bash
source /usr/local/lib/nix-pi/devshell.sh
exec "$@"
EOF

# Interactive shells (VS Code terminals, docker exec) enter the dev shell too.
RUN echo 'source /usr/local/lib/nix-pi/devshell.sh' >> /etc/bash.bashrc

WORKDIR /workspace
CMD ["bash"]
