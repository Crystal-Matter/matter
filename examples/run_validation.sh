#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

mkdir -p ./bin/

usage() {
  cat <<'EOF'
Run end-to-end commissioning + device validation against the local example device.

Defaults:
  - Builds `./bin/matter_switch` and `./bin/chip-tool-crystal`
  - Starts the device locally (UDP 5540)
  - Commissions Node 1 using the printed manual pairing code
  - Validates FixedLabel values using the selected `--chip-tool`
  - Runs `examples/device_validation.cr` using the same `--chip-tool`

Env vars:
  CRYSTAL_CACHE_DIR   Crystal cache directory (default: ./tmp/.crystal_cache)
  CHIP_TOOL           chip-tool binary for validation/commissioning (default: chip-tool)
  MATTER_PEER_ADDRESS Device address (default: 127.0.0.1:5540)

Options:
  --address ADDR      Device address ip[:port] (overrides MATTER_PEER_ADDRESS)
  --chip-tool PATH    chip-tool binary for validation (overrides CHIP_TOOL)
  --storage-a DIR     Storage directory for Fabric A (default: tmp/device_validation/chip-tool-a-<timestamp>)
  --skip-build        Skip building binaries
  --keep-device-state Don't delete `matter_switch_storage.yml` before starting
  --log PATH          Device stdout/stderr log path (default: ./bin/matter_switch_run.log)
  -h, --help          Show this help
EOF
}

ADDRESS="${MATTER_PEER_ADDRESS:-127.0.0.1:5540}"
CHIP_TOOL_BIN="${CHIP_TOOL:-chip-tool}"
STORAGE_A=""
SKIP_BUILD=0
KEEP_DEVICE_STATE=0
DEVICE_LOG="./bin/matter_switch_run.log"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --address)
      ADDRESS="${2:-}"; shift 2
      ;;
    --chip-tool)
      CHIP_TOOL_BIN="${2:-}"; shift 2
      ;;
    --storage-a)
      STORAGE_A="${2:-}"; shift 2
      ;;
    --skip-build)
      SKIP_BUILD=1; shift
      ;;
    --keep-device-state)
      KEEP_DEVICE_STATE=1; shift
      ;;
    --log)
      DEVICE_LOG="${2:-}"; shift 2
      ;;
    -h|--help)
      usage; exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

export CRYSTAL_CACHE_DIR="${CRYSTAL_CACHE_DIR:-./tmp/.crystal_cache}"
mkdir -p "$CRYSTAL_CACHE_DIR"

if [[ -z "$STORAGE_A" ]]; then
  STORAGE_A="./tmp/device_validation/chip-tool-a-$(date +%s)"
fi
mkdir -p "$STORAGE_A"

if [[ "$SKIP_BUILD" -ne 1 ]]; then
  echo "==> Building binaries"
  crystal build ./examples/chip-tool.cr -o ./bin/chip-tool-crystal --error-trace
  crystal build ./examples/matter_switch_device.cr -o ./bin/matter_switch --error-trace
fi

if [[ "$KEEP_DEVICE_STATE" -ne 1 ]]; then
  rm -f ./matter_switch_storage.yml
fi

echo "==> Starting device (log: $DEVICE_LOG)"
rm -f "$DEVICE_LOG"
./bin/matter_switch --no-interactive >"$DEVICE_LOG" 2>&1 &
DEV_PID=$!

cleanup() {
  kill "$DEV_PID" 2>/dev/null || true
  wait "$DEV_PID" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> Waiting for pairing code..."
for _ in $(seq 1 400); do
  if grep -q "chip-tool pairing code 1" "$DEVICE_LOG"; then
    break
  fi
  sleep 0.05
done

PAIR_LINE="$(grep "chip-tool pairing code 1" "$DEVICE_LOG" | head -n 1 || true)"
MANUAL_CODE="$(echo "$PAIR_LINE" | sed -n 's/.*chip-tool pairing code 1 \([0-9-]*\).*/\1/p')"

if [[ -z "$MANUAL_CODE" ]]; then
  echo "ERROR: failed to extract manual pairing code from log" >&2
  tail -n 120 "$DEVICE_LOG" >&2 || true
  exit 1
fi

echo "==> Pairing code: $MANUAL_CODE"

chip_tool_supports_address=0
{
  set +e
  pairing_help="$("$CHIP_TOOL_BIN" pairing code --help 2>&1)"
  set -e
  if echo "$pairing_help" | grep -q -- "--address"; then
    chip_tool_supports_address=1
  fi
}

echo "==> Commissioning with $CHIP_TOOL_BIN (storage: $STORAGE_A)"
if [[ "$chip_tool_supports_address" -eq 1 ]]; then
  "$CHIP_TOOL_BIN" pairing code 1 "$MANUAL_CODE" --address "$ADDRESS" --allow-test-attestation --storage-directory "$STORAGE_A"
else
  "$CHIP_TOOL_BIN" pairing code 1 "$MANUAL_CODE" --storage-directory "$STORAGE_A" --commissioner-name alpha
fi

strip_ansi() {
  # Remove ANSI color codes commonly emitted by chip-tool.
  sed -r 's/\x1B\[[0-9;]*[A-Za-z]//g'
}

check_fixed_labels_example_prefix() {
  local output values bad exit_code
  echo "==> Reading FixedLabel LabelList with $CHIP_TOOL_BIN"
  set +e
  if [[ "$chip_tool_supports_address" -eq 1 ]]; then
    output="$("$CHIP_TOOL_BIN" fixedlabel read label-list 1 1 --storage-directory "$STORAGE_A" 2>&1)"
  else
    output="$("$CHIP_TOOL_BIN" fixedlabel read label-list 1 1 --storage-directory "$STORAGE_A" --commissioner-name alpha 2>&1)"
  fi
  exit_code=$?
  set -e

  if [[ "$exit_code" -ne 0 ]] || echo "$output" | grep -Eq "Run command failure|Error 0x" ; then
    echo "ERROR: FixedLabel read failed via $CHIP_TOOL_BIN" >&2
    echo "$output" >&2
    return 1
  fi

  # Official `chip-tool` prints either `Value: Example Foo` or `value: "Example Foo"` depending on verbosity/version.
  # `chip-tool-crystal` prints `value="Example Foo"`.
  values="$(echo "$output" | strip_ansi | sed -nE \
    -e 's/.*value=\"([^\"]+)\".*/\1/p' \
    -e 's/.*[Vv]alue: *\"?([^\"]+)\"?.*/\1/p')"
  if [[ -z "$values" ]]; then
    echo "ERROR: FixedLabel output did not contain any label values" >&2
    echo "$output" >&2
    return 1
  fi

  echo "==> FixedLabel values:"
  bad=0
  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    echo " - $v"
    if [[ "$v" != Example* ]]; then
      echo "ERROR: FixedLabel value does not start with \"Example\": $v" >&2
      bad=1
    fi
  done <<<"$values"

  [[ "$bad" -eq 0 ]]
}

check_fixed_labels_example_prefix

echo "==> Running device validation (chip-tool: $CHIP_TOOL_BIN)"
export CHIP_TOOL="$CHIP_TOOL_BIN"
export MATTER_PEER_ADDRESS="$ADDRESS"
export CHIP_TOOL_SUPPORTS_ADDRESS="$chip_tool_supports_address"
crystal run ./examples/device_validation.cr -- --chip-tool "$CHIP_TOOL_BIN" --storage-a "$STORAGE_A"

echo "==> PASS"
