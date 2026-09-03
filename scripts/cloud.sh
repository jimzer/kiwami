#!/usr/bin/env bash
# A bare-metal builder, rented by the hour.
#
# macOS cannot build Linux derivations, so every ISO today goes through a VM:
# push the tree in, build inside the guest, copy 1.5G back out. That loop is
# slow, it is single-VM-at-a-time, and it has already produced one silent
# failure - a push to a guest that was not running, which built nothing and
# reported success. A Linux box with KVM removes the whole detour.
#
# Elastic Metal because it is real hardware: nested virtualization is off on
# every cheap VPS, and `nixosTest` is QEMU, so a VM without /dev/kvm cannot
# run the tests at all.
#
# There is no persistent disk and no snapshot on Elastic Metal - Scaleway
# supports neither for this range - so a server is created and destroyed each
# session and the Nix store starts cold. That is the trade for the price.
# Everything needed to make a fresh box useful lives in cloud-bootstrap.sh, so
# "set it up" is one script rather than remembered steps.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Named, not remembered. Every command below finds the server by this tag, so
# there is no id to keep track of and no way to create a second one by
# accident.
TAG="${KIWAMI_CLOUD_TAG:-kiwami-builder}"
ZONE="${KIWAMI_CLOUD_ZONE:-fr-par-2}"
OFFER="${KIWAMI_CLOUD_OFFER:-EM-A115X-SSD}"   # Aluminium, 4C/32G
IMAGE="${KIWAMI_CLOUD_IMAGE:-ubuntu_jammy}"
RATE="${KIWAMI_CLOUD_RATE:-0.077}"            # EUR/hour, for the cost line

cyan() { printf '\033[1;36m%s\033[0m\n' "$1"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$1"; }
die()  { printf '\033[1;31m%s\033[0m\n' "$1" >&2; exit 1; }

need_scw() {
    command -v scw >/dev/null || die "scw is not installed.
  brew install scw        (then: scw init)
It needs an API key from the Scaleway console under IAM > API keys."
    scw config get default-project-id >/dev/null 2>&1 \
        || die "scw is installed but not configured. Run: scw init"
}

# The server's id, or empty. Everything keys off this.
server_id() {
    scw baremetal server list zone="$ZONE" tags."0"="$TAG" -o json 2>/dev/null \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["id"] if d else "")' 2>/dev/null || true
}

server_field() {
    scw baremetal server get "$1" zone="$ZONE" -o json 2>/dev/null \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('$2',''))" 2>/dev/null || true
}

server_ip() {
    scw baremetal server get "$1" zone="$ZONE" -o json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
ips = d.get("ips") or []
# IPv4 first: the harness ssh-es from a Mac that may have no v6 route.
v4 = [i["address"] for i in ips if i.get("version") == "IPv4"]
print((v4 or [i["address"] for i in ips] or [""])[0])
' 2>/dev/null || true
}

cmd_up() {
    need_scw

    local id
    id="$(server_id)"
    if [ -n "$id" ]; then
        cyan "==> already up"
        cmd_status
        return 0
    fi

    # The key is uploaded to the project, not baked into an image, and is
    # injected at install time - so a fresh box is reachable the moment it
    # finishes installing, with no password anywhere.
    local keys
    keys="$(scw iam ssh-key list -o json | python3 -c 'import json,sys; print(",".join(k["id"] for k in json.load(sys.stdin)))')"
    [ -n "$keys" ] || die "no SSH keys in this project.
Add one first:  scw iam ssh-key create name=$(hostname -s) public-key=\"\$(cat ~/.ssh/id_ed25519.pub)\""

    cyan "==> renting $OFFER in $ZONE (~EUR $RATE/hour, billed until destroyed)"
    id="$(scw baremetal server create zone="$ZONE" type="$OFFER" name="$TAG" tags.0="$TAG" \
            install.os-id="$IMAGE" install.ssh-key-ids="$keys" -o json \
          | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')" \
        || die "could not create the server. Elastic Metal stock varies by zone -
try another with KIWAMI_CLOUD_ZONE=fr-par-1, or check the console."

    cyan "==> installing $IMAGE (this takes a few minutes)"
    local state
    for _ in $(seq 1 120); do
        state="$(server_field "$id" status)"
        [ "$state" = "ready" ] && break
        sleep 15
    done
    [ "$state" = "ready" ] || die "the server never became ready (last state: $state)"

    local ip
    ip="$(server_ip "$id")"
    cyan "==> $ip is up; setting it up"
    until ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "root@$ip" true 2>/dev/null; do
        sleep 5
    done
    ssh "root@$ip" 'bash -s' < "$DIR/cloud-bootstrap.sh"

    echo
    cyan "==> ready"
    echo "  ssh root@$ip"
    echo "  just cloud-down     when you are finished - it bills until destroyed"
}

cmd_status() {
    need_scw
    local id
    id="$(server_id)"
    if [ -z "$id" ]; then
        echo "no builder running"
        return 0
    fi

    local ip created
    ip="$(server_ip "$id")"
    created="$(server_field "$id" created_at)"

    # Hours and euros, printed every time. The failure mode with hourly
    # billing is not technical, it is forgetting - so the number is never more
    # than one command away.
    python3 - "$created" "$RATE" "$ip" "$(server_field "$id" status)" <<'PY'
import datetime, sys
created, rate, ip, status = sys.argv[1], float(sys.argv[2]), sys.argv[3], sys.argv[4]
try:
    started = datetime.datetime.fromisoformat(created.replace("Z", "+00:00"))
    hours = (datetime.datetime.now(datetime.timezone.utc) - started).total_seconds() / 3600
    print(f"  builder   {ip}  ({status})")
    print(f"  running   {hours:.1f}h  -  about EUR {hours * rate:.2f} so far")
except Exception:
    print(f"  builder   {ip}  ({status})")
PY
}

cmd_ssh() {
    need_scw
    local id ip
    id="$(server_id)"; [ -n "$id" ] || die "no builder running (just cloud-up)"
    ip="$(server_ip "$id")"
    shift || true
    if [ $# -gt 0 ]; then ssh "root@$ip" "$@"; else ssh "root@$ip"; fi
}

cmd_down() {
    need_scw
    local id
    id="$(server_id)"
    if [ -z "$id" ]; then
        echo "no builder running"
        return 0
    fi

    cmd_status
    # There is no snapshot on Elastic Metal, so this is not "stop" - the disk
    # goes with it. Anything worth keeping has to already be somewhere else.
    warn "
This destroys the machine and everything on it. Elastic Metal has no
snapshots, so the Nix store is gone and the next one starts cold."
    read -r -p "Type 'yes' to destroy it: " answer
    [ "$answer" = "yes" ] || { echo "left running"; return 1; }

    scw baremetal server delete "$id" zone="$ZONE" >/dev/null
    cyan "==> destroyed; billing stopped"
}

case "${1:-status}" in
    up) cmd_up ;;
    status) cmd_status ;;
    ssh) cmd_ssh "$@" ;;
    down) cmd_down ;;
    *) die "usage: cloud.sh [up|status|ssh|down]" ;;
esac
