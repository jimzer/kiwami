#!/usr/bin/env bash
# Turn a bare Ubuntu box into something that can build Kiwami and run its VM
# tests. Runs on the server, over ssh, from cloud.sh.
#
# Plain Ubuntu rather than NixOS on purpose: nixosTest needs Nix, Linux and
# /dev/kvm, not NixOS. An apt image plus the Nix installer is two minutes and
# no custom image; installing NixOS on bare metal each session would be the
# only hard part of an otherwise trivial setup.
#
# Everything here is idempotent, so re-running it on a live box is safe.
set -euo pipefail

cyan() { printf '\033[1;36m%s\033[0m\n' "$1"; }
no()   { printf '\033[1;31m%s\033[0m\n' "$1" >&2; exit 1; }

# The reason this machine exists. Checked first, because everything after it
# is wasted effort on a box that cannot run a VM - and a cheap VPS that
# quietly lacks this would otherwise look identical until the first test.
cyan "==> hardware virtualization"
grep -qE '(vmx|svm)' /proc/cpuinfo || no "no vmx/svm in /proc/cpuinfo - this is not bare metal"
[ -e /dev/kvm ] || no "/dev/kvm missing - KVM is not available here"
echo "    $(grep -cE '(vmx|svm)' /proc/cpuinfo) cores report virtualization, /dev/kvm present"

cyan "==> packages"
export DEBIAN_FRONTEND=noninteractive
# A freshly installed box is still running cloud-init and unattended-upgrades,
# which hold the apt lock for the first minute or two. Racing them fails with
# "Could not get lock", which reads like a broken image and is really just
# arriving early - the same mistake the installer made with NetworkManager.
if command -v cloud-init >/dev/null 2>&1; then
    cloud-init status --wait >/dev/null 2>&1 || true
fi
for _ in $(seq 1 60); do
    fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break
    sleep 5
done
apt-get update -qq
# qemu for the tests, git because the flake is fetched, curl for the installer.
apt-get install -y -qq curl git xz-utils qemu-system-x86 qemu-utils >/dev/null

cyan "==> nix"
# The path, not the command: under sudo with a fresh shell nix is not on
# PATH even when it is installed, so `command -v` says no and the installer
# runs again - which then refuses, having found its own leftover backup of
# /etc/bash.bashrc, and fails the whole bootstrap on a box that was fine.
if [ ! -e /nix/var/nix/profiles/default/bin/nix ]; then
    # Single-user install: this box has exactly one user and is destroyed at
    # the end of the session, so the daemon buys nothing and the multi-user
    # installer is the fiddly one on a non-systemd-init container or a fresh
    # cloud image.
    curl -fsSL https://nixos.org/nix/install | sh -s -- --daemon --yes
fi
# shellcheck disable=SC1091
. /etc/profile.d/nix.sh 2>/dev/null || . "$HOME/.nix-profile/etc/profile.d/nix.sh"

cyan "==> nix.conf"
mkdir -p /etc/nix
# nixos-test and kvm are what let `nixosTest` derivations run at all: without
# them in system-features Nix refuses the build rather than running it slowly,
# which is the right behaviour and a confusing error if you do not know it.
cat > /etc/nix/nix.conf <<'CONF'
experimental-features = nix-command flakes
system-features = nixos-test benchmark big-parallel kvm
max-jobs = auto
# The binary cache is on the other side of a datacenter link here, so a cold
# store costs minutes rather than the half hour it would at home. This is what
# makes a machine with no persistent disk tolerable.
substituters = https://cache.nixos.org
CONF
systemctl restart nix-daemon 2>/dev/null || true

cyan "==> checking it works"
nix --version
nix eval --expr '1 + 1' --impure >/dev/null && echo "    nix evaluates"

# A self-destruct timer, opt-in through the environment.
#
# Elastic Metal bills while the server is allocated, whatever its power state,
# so a forgotten box costs about EUR 1.85 a day and a forgotten fortnight
# costs real money. This caps the damage without depending on a laptop being
# awake to run a cron job.
if [ -n "${KIWAMI_CLOUD_MAX_HOURS:-}" ]; then
    cyan "==> self-destruct in ${KIWAMI_CLOUD_MAX_HOURS}h"
    if [ -z "${SCW_SECRET_KEY:-}" ]; then
        echo "    skipped: needs SCW_SECRET_KEY on the server to call the API"
    else
        cat > /usr/local/bin/kiwami-selfdestruct <<EOF
#!/usr/bin/env bash
# Deletes this server through the API. Powering off would not stop the bill.
curl -s -X DELETE \\
  -H "X-Auth-Token: \$SCW_SECRET_KEY" \\
  "https://api.scaleway.com/baremetal/v1/zones/${KIWAMI_CLOUD_ZONE:-fr-par-2}/servers/\$(cat /etc/kiwami-server-id)"
EOF
        chmod +x /usr/local/bin/kiwami-selfdestruct
        echo "SCW_SECRET_KEY=$SCW_SECRET_KEY" > /etc/kiwami-cloud.env
        chmod 600 /etc/kiwami-cloud.env
        systemd-run --on-active="${KIWAMI_CLOUD_MAX_HOURS}h" \
            --unit=kiwami-selfdestruct \
            --setenv=SCW_SECRET_KEY="$SCW_SECRET_KEY" \
            /usr/local/bin/kiwami-selfdestruct >/dev/null
    fi
fi

echo
cyan "==> the builder is ready"
echo "    nix $(nix --version | awk '{print $3}'), kvm available, $(nproc) cores, $(free -g | awk '/^Mem:/{print $2}')G RAM"
