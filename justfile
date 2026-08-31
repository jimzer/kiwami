# Kiwami — top-level command interface.
#
# Subsystems expose their own justfile and are mounted here as modules, so
# `just vm <recipe>` is the stable API while vm/scripts/* can change freely.
#   just            list everything
#   just vm         list the vm subsystem
#   just vm start   run a subsystem recipe

set shell := ["bash", "-uc"]

# Dev VM: build, boot, drive, screenshot, snapshot
mod vm

# List available commands
default:
    @just --list --unsorted

# NOTE: a bare `for` loop returns only its LAST iteration's status, so a
# failure in the middle would be silently swallowed - hence the rc tracking.

# Everything CI's `evaluate` job does, locally. This is the check that would
# have caught a module being deleted while two files still imported it -
# `just lint` never will, because it does not evaluate any Nix.
eval:
    #!/usr/bin/env bash
    set -euo pipefail
    # `just` runs recipes in a non-interactive shell, which never sources the
    # profile snippet that puts nix on PATH.
    command -v nix >/dev/null || export PATH="/nix/var/nix/profiles/default/bin:$PATH"

    hosts=$(nix eval --json '.#nixosConfigurations' --apply builtins.attrNames \
              | tr -d '[]"' | tr ',' ' ')
    # An empty list here is a failure, not a pass. Silently iterating over
    # nothing is exactly how a broken check reports success forever.
    [ -n "${hosts// /}" ] || { echo "  no hosts found - is the flake broken?"; exit 1; }

    for h in $hosts "desktop-test"; do
      case "$h" in
        desktop-test) attr='.#checks.x86_64-linux.desktop.drvPath' ;;
        *)            attr=".#nixosConfigurations.$h.config.system.build.toplevel.drvPath" ;;
      esac
      printf '  %-14s ' "$h"
      # Nix warns about the dirty git tree on every call; only worth seeing
      # when something actually fails.
      if err=$(nix eval --raw "$attr" 2>&1 >/dev/null); then
        echo ok
      else
        echo FAIL; echo "$err" >&2; exit 1
      fi
    done

# Syntax of every script and justfile. Fast; evaluates no Nix.
lint:
    @rc=0; for f in vm/scripts/*.sh; do \
        if bash -n "$f"; then echo "ok   $f"; else echo "FAIL $f"; rc=1; fi; done; \
      for f in vm/scripts/*.py; do \
        if python3 -c "import ast,sys;ast.parse(open(sys.argv[1]).read())" "$f"; \
        then echo "ok   $f"; else echo "FAIL $f"; rc=1; fi; done; \
      for j in justfile vm/justfile; do \
        if just --justfile "$j" --summary >/dev/null 2>&1; then echo "ok   $j"; else echo "FAIL $j"; rc=1; fi; done; \
      exit $rc

# Everything that can be verified without a Linux builder.
check: lint eval

# Show repo layout, ignoring build artifacts
tree:
    @git ls-files
