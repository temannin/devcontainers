#!/bin/sh
set -e
# Host keys: generated on first start, then kept with the container.
ssh-keygen -A
printf '%s\n' "$SSH_PUBLIC_KEY" > /etc/ssh/intellij_authorized_keys
chmod 644 /etc/ssh/intellij_authorized_keys
# Where /etc/profile.d/zz-intellij-project.sh takes SSH logins.
printf '%s\n' "$PROJECT_DIR" > /etc/intellij-project
mkdir -p /run/sshd
# On the host network (SSH_PORT set) sshd listens on 127.0.0.1:<port>, which
# WSL forwards to Windows; otherwise on port 22, published by the engine.
if [ -n "$SSH_PORT" ]; then
  exec /usr/sbin/sshd -D -e -p "$SSH_PORT" -o ListenAddress=127.0.0.1
fi
exec /usr/sbin/sshd -D -e
