#!/usr/bin/env bash
#
# Put the Relay on a fresh Linux host.
#
#   scp -r deploy install-relay.sh <host>:/tmp/ && ssh <host> 'sudo bash /tmp/deploy/install-relay.sh'
#
# Idempotent: safe to re-run to upgrade. It installs Node if missing, checks out
# the repository, builds, creates a service account, and starts the unit. It
# does **not** open a firewall port — the Relay binds loopback and is reached
# through a Cloudflare tunnel, which is what makes this work on a mainland
# Chinese host whose domain cannot be ICP-filed.

set -euo pipefail

REPO="${REINS_REPO:-https://github.com/0x5446/reins.git}"
REF="${REINS_REF:-main}"
PREFIX="${REINS_PREFIX:-/opt/reins}"
SERVICE_USER="${REINS_USER:-reins}"

[ "$(id -u)" -eq 0 ] || { echo "run this with sudo" >&2; exit 1; }

step() { printf '\n==> %s\n' "$*"; }

# --- Node --------------------------------------------------------------------

need_node() {
  command -v node >/dev/null 2>&1 || return 0
  [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 22 ]
}

if need_node; then
  step "Installing Node 22"
  # NodeSource rather than the distribution package: Ubuntu ships whatever it
  # shipped, and the Relay needs 22 for its WebSocket and crypto APIs.
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi
node -v

# --- Service account ---------------------------------------------------------

if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  step "Creating the $SERVICE_USER service account"
  # No login shell and no home: this account exists to own one process.
  useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
fi

# --- Source ------------------------------------------------------------------

step "Fetching $REF"
if [ -d "$PREFIX/.git" ]; then
  git -C "$PREFIX" fetch --quiet --depth 1 origin "$REF"
  git -C "$PREFIX" checkout --quiet FETCH_HEAD
else
  mkdir -p "$(dirname "$PREFIX")"
  git clone --quiet --depth 1 --branch "$REF" "$REPO" "$PREFIX"
fi

step "Building"
cd "$PREFIX"
npm ci --silent --no-audit --no-fund
npx tsc -b protocol relay

# The service account only ever reads. Anything it could write is a way for a
# relay compromise to become a persistent one.
chown -R root:root "$PREFIX"
chmod -R a+rX "$PREFIX"

# --- Service -----------------------------------------------------------------

step "Installing the unit"
install -m 0644 "$PREFIX/deploy/relay.service" /etc/systemd/system/reins-relay.service
systemctl daemon-reload
systemctl enable --now reins-relay

sleep 2
step "Checking"
systemctl is-active --quiet reins-relay && echo "service: active" || {
  echo "service failed to start:" >&2
  journalctl -u reins-relay -n 30 --no-pager >&2
  exit 1
}
curl -fsS --max-time 5 http://127.0.0.1:8787/healthz && echo

cat <<'DONE'

The Relay is running on 127.0.0.1:8787 and is not reachable from outside.

Next, point a Cloudflare tunnel at it:

  cloudflared tunnel run --token <token from the Zero Trust dashboard>

with the tunnel's public hostname configured as reins.novabox.ai → http://127.0.0.1:8787
DONE
