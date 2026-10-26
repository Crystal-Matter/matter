#!/bin/sh
# Build the example binaries for the Docker E2E images. The optional list is
# supplied by ./test --focused; the default builds every example and fixture.
set -eu

case "${MATTER_E2E_BUILD_JOBS:-2}" in
  1|2) ;;
  *) echo 'MATTER_E2E_BUILD_JOBS must be 1 or 2' >&2; exit 1 ;;
esac

mkdir -p bin

source_for() {
  name="$1"
  case "$name" in
    device_validation) source=examples/device_validation.cr ;;
    matter_*)
      source="e2e/fixture/${name}_device.cr"
      if [ ! -f "$source" ]; then
        source="examples/${name}_device.cr"
      fi
      ;;
    *) echo "Invalid E2E binary: $name" >&2; return 1 ;;
  esac
  if [ ! -f "$source" ]; then
    echo "No source for E2E binary: $name" >&2
    return 1
  fi
  printf '%s\n' "$source"
}

if [ -n "${MATTER_E2E_BINARIES:-}" ]; then
  binaries="$MATTER_E2E_BINARIES"
else
  binaries=device_validation
  for source in examples/matter_*_device.cr e2e/fixture/matter_*_device.cr; do
    [ -f "$source" ] || continue
    name="$(basename "$source" _device.cr)"
    case " $binaries " in
      *" $name "*) ;;
      *) binaries="$binaries $name" ;;
    esac
  done
fi

# Resolve and validate every name before starting any compiler processes.
sources=""
for name in $binaries; do
  case "$name" in
    *[!a-zA-Z0-9_]*|'') echo "Invalid E2E binary: $name" >&2; exit 1 ;;
  esac
  source="$(source_for "$name")" || exit 1
  sources="$sources $name:$source"
done

printf '%s\n' $sources | xargs -P "$MATTER_E2E_BUILD_JOBS" -I{} sh -c '
  name="${1%%:*}"
  source="${1#*:}"
  echo "==> building bin/$name from $source"
  CRYSTAL_CACHE_DIR="/root/.cache/crystal/$name" crystal build "$source" -o "bin/$name" --error-trace
' sh '{}'
