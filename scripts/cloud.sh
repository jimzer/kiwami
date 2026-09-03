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
OFFER="${KIWAMI_CLOUD_OFFER:-EM-A116X-SSD}"   # Aluminium: 4 cores, 29G, EUR 0.077/h
IMAGE="${KIWAMI_CLOUD_IMAGE:-Ubuntu 24.04}"
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

# Zones to look in. Stock moves around, so the box does not always end up
# where the default says - and nothing records where it went. Searching by tag
# across all of them means `status` and `down` cannot miss a running server,
# which with hourly billing is the failure that actually costs money.
ZONES="${KIWAMI_CLOUD_ZONES:-fr-par-1 fr-par-2 nl-ams-1 pl-waw-2}"

# Sets SERVER_ID, and moves ZONE to wherever the server actually is. Not a
# command substitution: this has to change ZONE for the caller, and a subshell
# could not.
SERVER_ID=""
find_server() {
    SERVER_ID=""
    local z id
    for z in $ZONES; do
        id="$(scw baremetal server list zone="$z" tags."0"="$TAG" -o json 2>/dev/null \
            | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["id"] if d else "")' 2>/dev/null || true)"
        if [ -n "$id" ]; then
            SERVER_ID="$id"
            ZONE="$z"
            return 0
        fi
    done
    return 1
}

server_field() {
    scw baremetal server get "$1" zone="$ZONE" -o json 2>/dev/null \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('$2',''))" 2>/dev/null || true
}

# The OS install runs after the hardware is allocated, and has its own status.
# The server-level one goes "ready" while install.status is still
# "installing" - so waiting on the wrong field lands you at a half-built
# machine whose host key changes under you a minute later.
install_field() {
    scw baremetal server get "$1" zone="$ZONE" -o json 2>/dev/null | python3 -c "
import json, sys
print((json.load(sys.stdin).get('install') or {}).get('$2', ''))
" 2>/dev/null || true
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
    find_server || true
    id="$SERVER_ID"
    if [ -n "$id" ]; then
        cyan "==> already up"
        cmd_status
        return 0
    fi

    # The key is uploaded to the project, not baked into an image, and is
    # injected at install time - so a fresh box is reachable the moment it
    # finishes installing, with no password anywhere.
    # scw wants array arguments indexed - install.ssh-key-ids.0=<id> - and
    # rejects a comma-separated list with "missing index on the array". It
    # fails before anything is rented, which is the good kind of failure.
    local keyargs
    keyargs="$(scw iam ssh-key list -o json 2>/dev/null | python3 -c '
import json, sys
keys = json.load(sys.stdin)
print(" ".join("install.ssh-key-ids.%d=%s" % (i, k["id"]) for i, k in enumerate(keys)))
' 2>/dev/null)"
    [ -n "$keyargs" ] || die "no SSH keys in this project.
Add one first:  scw iam ssh-key create name=mac public-key=\"\$(cat ~/.ssh/id_rsa.pub)\""

    cyan "==> renting $OFFER in $ZONE (~EUR $RATE/hour, billed until destroyed)"
    # The image is named, not an id: `scw baremetal os list` gives ids per
    # zone, and the name is stable across them.
    local os_id
    os_id="$(scw baremetal os list zone="$ZONE" -o json 2>/dev/null | IMAGE="$IMAGE" python3 -c "
import json, os, sys
want = os.environ['IMAGE'].lower()
for o in json.load(sys.stdin):
    if want in (o.get('name','') + ' ' + o.get('version','')).lower():
        print(o['id']); break
" 2>/dev/null)"
    [ -n "$os_id" ] || die "no image matching $IMAGE in $ZONE (see: scw baremetal os list zone=$ZONE)"

    local created
    # shellcheck disable=SC2086
    created="$(scw baremetal server create zone="$ZONE" type="$OFFER" name="$TAG" tags.0="$TAG" \
            install.os-id="$os_id" $keyargs -o json 2>&1)" || true
    id="$(printf '%s' "$created" | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["id"])
except Exception: pass' 2>/dev/null)"
    [ -n "$id" ] || die "could not create the server:
$created

Elastic Metal stock varies by zone - try KIWAMI_CLOUD_ZONE=fr-par-1, and
check that the account has a payment method and verified identity."

    cyan "==> installing $IMAGE (this takes a few minutes)"
    local state
    for _ in $(seq 1 160); do
        state="$(install_field "$id" status)"
        [ "$state" = "completed" ] && break
        sleep 15
    done
    [ "$state" = "completed" ] || die "the OS never finished installing (last state: $state)"

    local ip user
    ip="$(server_ip "$id")"
    # Scaleway's images create an unprivileged user rather than enabling root
    # logins - "ubuntu" here, but it is reported per install, so it is read
    # rather than assumed.
    user="$(install_field "$id" user)"
    user="${user:-ubuntu}"
    cyan "==> $ip is up; setting it up"
    # Rented addresses are recycled, and the host key changes when the OS is
    # installed - so a pinned key from an earlier box (or from this one, mid
    # install) makes every later connection fail closed with "host key
    # verification failed". Forget it first: this is a machine that did not
    # exist ten minutes ago and will not exist tomorrow, so there is no
    # identity to pin.
    ssh-keygen -R "$ip" >/dev/null 2>&1 || true
    until ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$user@$ip" true 2>/dev/null; do
        sleep 5
    done
    ssh "$user@$ip" 'sudo bash -s' < "$DIR/cloud-bootstrap.sh"

    echo
    cyan "==> ready"
    echo "  ssh $user@$ip"
    echo "  just cloud-down     when you are finished - it bills until destroyed"
}

cmd_status() {
    need_scw
    local id
    find_server || true
    id="$SERVER_ID"
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
    find_server || true
    id="$SERVER_ID"; [ -n "$id" ] || die "no builder running (just cloud-up)"
    ip="$(server_ip "$id")"
    local user
    user="$(install_field "$id" user)"; user="${user:-ubuntu}"
    shift || true
    ssh-keygen -R "$ip" >/dev/null 2>&1 || true
    local o=(-o StrictHostKeyChecking=accept-new)
    if [ $# -gt 0 ]; then ssh "${o[@]}" "$user@$ip" "$@"; else ssh "${o[@]}" "$user@$ip"; fi
}

cmd_down() {
    need_scw
    local id
    find_server || true
    id="$SERVER_ID"
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

# Run the nixosTests up here, where they can actually run: nixosTest is QEMU
# and needs /dev/kvm, which no Mac and no cheap VPS provides.
cmd_test() {
    need_scw
    local id ip user
    find_server || true
    id="$SERVER_ID"; [ -n "$id" ] || die "no builder running (just cloud-up)"
    ip="$(server_ip "$id")"
    user="$(install_field "$id" user)"; user="${user:-ubuntu}"
    ssh-keygen -R "$ip" >/dev/null 2>&1 || true

    # accept-new every time, because the line above just forgot the key. The
    # forgetting is deliberate - rented addresses are recycled and the key
    # changes when the OS is installed - but dropping it without accepting the
    # replacement just fails closed, which is how the first remote test run
    # died before it started.
    local SSHOPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

    local what="${1:-}"
    local flake="${KIWAMI_CLOUD_FLAKE:-github:jimzer/kiwami}"

    # The flake is fetched from GitHub rather than pushed. Whatever is on the
    # builder is then exactly what CI and a real install would get, and there
    # is no copy step to go stale - which is how the last harness managed to
    # test an ISO that predated the fix it was testing.
    if [ -n "$what" ]; then
        cyan "==> running checks.$what from $flake"
        ssh "${SSHOPTS[@]}" "$user@$ip" \
            ". /etc/profile.d/nix.sh 2>/dev/null || . ~/.nix-profile/etc/profile.d/nix.sh; \
             nix build --no-link --print-build-logs '$flake#checks.x86_64-linux.$what'"
    else
        cyan "==> running every check from $flake"
        ssh "${SSHOPTS[@]}" "$user@$ip" \
            ". /etc/profile.d/nix.sh 2>/dev/null || . ~/.nix-profile/etc/profile.d/nix.sh; \
             nix flake check --print-build-logs '$flake'"
    fi
}

case "${1:-status}" in
    up) cmd_up ;;
    test) shift || true; cmd_test "$@" ;;
    status) cmd_status ;;
    ssh) cmd_ssh "$@" ;;
    down) cmd_down ;;
    *) die "usage: cloud.sh [up|status|ssh|test|down]" ;;
esac
