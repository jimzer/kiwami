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

# Check that every script and justfile parses
check:
    @rc=0; for f in vm/scripts/*.sh; do \
        if bash -n "$f"; then echo "ok   $f"; else echo "FAIL $f"; rc=1; fi; done; \
      for f in vm/scripts/*.py; do \
        if python3 -c "import ast,sys;ast.parse(open(sys.argv[1]).read())" "$f"; \
        then echo "ok   $f"; else echo "FAIL $f"; rc=1; fi; done; \
      for j in justfile vm/justfile; do \
        if just --justfile "$j" --summary >/dev/null 2>&1; then echo "ok   $j"; else echo "FAIL $j"; rc=1; fi; done; \
      exit $rc

# Show repo layout, ignoring build artifacts
tree:
    @find . -type f -not -path './vm/disks/*' -not -path './vm/iso/*' \
        -not -path './vm/keys/*' -not -path './.git/*' -not -name '*.png' | sort
