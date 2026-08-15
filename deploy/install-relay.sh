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
# HEAD, not a release tag. `install.sh` pins the *user-facing* install to a tag
# because a user should get a version someone shipped on purpose; an operator
# deploying their own relay is choosing the version by choosing when to run this.
REF="${REINS_REF:-main}"
PREFIX="${REINS_PREFIX:-/opt/reins}"
SERVICE_USER="${REINS_USER:-reins}"
# A tarball to unpack instead of a clone. While the repository is private, a
# host with no GitHub credentials cannot clone it, and putting a deploy key on
# the relay would give a relay compromise a way into the source:
#   git archive --format=tar HEAD | gzip > /tmp/reins-src.tgz
#   scp /tmp/reins-src.tgz <host>:/tmp/
#   ssh <host> 'sudo REINS_TARBALL=/tmp/reins-src.tgz bash /tmp/deploy/install-relay.sh'
TARBALL="${REINS_TARBALL:-}"

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

if [ -n "$TARBALL" ]; then
  step "Unpacking $TARBALL"
  [ -f "$TARBALL" ] || { echo "no such tarball: $TARBALL" >&2; exit 1; }
  # Replace rather than overlay: a file deleted upstream must not survive an
  # upgrade, and a stale compiled artifact is worse than no artifact.
  rm -rf "$PREFIX"
  mkdir -p "$PREFIX"
  tar xzf "$TARBALL" -C "$PREFIX"
else
  step "Fetching $REF"
  if [ -d "$PREFIX/.git" ]; then
    git -C "$PREFIX" fetch --quiet --depth 1 origin "$REF"
    git -C "$PREFIX" checkout --quiet FETCH_HEAD
  else
    mkdir -p "$(dirname "$PREFIX")"
    git clone --quiet --depth 1 --branch "$REF" "$REPO" "$PREFIX"
  fi
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

Next, point a Cloudflare tunnel at it. A locally-managed tunnel, not a
dashboard-managed one: the login below writes a cert that can create the DNS
record itself, and the ingress lives in a file you can diff.

  cloudflared tunnel login
  cloudflared tunnel create reins-relay
  cloudflared tunnel route dns reins-relay reins.novabox.ai

Then put the ingress in /etc/cloudflared/config.yml —

  tunnel: <id printed by create>
  credentials-file: /etc/cloudflared/reins-relay.json
  ingress:
    - hostname: reins.novabox.ai
      service: http://127.0.0.1:8787
    - service: http_status:404

— and install it:

  cloudflared --config /etc/cloudflared/config.yml tunnel ingress validate
  cloudflared service install

Verify from somewhere else, not from this host:

  curl -fsS https://reins.novabox.ai/healthz
DONE
