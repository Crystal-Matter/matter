#!/usr/bin/env bash
set -euo pipefail

# Native Linux x64: FabricAdmin and FabricBridge share loopback Pigweed RPC.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
sdk_root="${MATTER_SDK_ROOT:-${repo_root}/tmp/connectedhomeip}"
log_dir="${MATTER_INTEROP_LOG_DIR:-${repo_root}/tmp/interop-sdk-reverse}"
sdk_tag="v1.6.0.0"

if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
  echo "SDK reverse commissioning requires Linux x86_64" >&2
  exit 2
fi

if [[ ! -d "${sdk_root}/.git" ]]; then
  mkdir -p "$(dirname "${sdk_root}")"
  git clone --depth 1 --branch "${sdk_tag}" \
    https://github.com/project-chip/connectedhomeip.git "${sdk_root}"
fi

if [[ "$(git -C "${sdk_root}" describe --tags --exact-match HEAD)" != "${sdk_tag}" ]]; then
  echo "SDK checkout must be exactly ${sdk_tag}: ${sdk_root}" >&2
  exit 2
fi

mkdir -p "${log_dir}"
if [[ "${MATTER_INTEROP_SKIP_BUILD:-0}" != 1 ]]; then
  (
    cd "${sdk_root}"
    ./scripts/checkout_submodules.py --shallow --platform linux
    python3 - <<'PY'
import json
from pathlib import Path

config = json.loads(Path("scripts/setup/environment.json").read_text())
config["cipd_package_files"] = [
    package for package in config["cipd_package_files"]
    if not package.endswith("/arm.json")
]
Path("objdir-reverse-environment.json").write_text(json.dumps(config))
PY
    export PW_CONFIG_FILE=objdir-reverse-environment.json
    set +u
    source scripts/bootstrap.sh -p linux
    set -u
    ./scripts/build/build_examples.py \
      --target linux-x64-fabric-admin-ipv6only-no-ble-no-wifi-clang-rpc \
      --target linux-x64-fabric-bridge-ipv6only-no-ble-no-wifi-clang-rpc \
      --build-profile debug build --copy-artifacts-to objdir-reverse
  ) 2>&1 | tee "${log_dir}/sdk-build.log"

  (
    cd "${repo_root}"
    crystal build examples/matter_reverse_commissioning_device.cr \
      -o "${log_dir}/matter_reverse_aggregator"
    crystal build e2e/interop/sdk_reverse_commissioning_driver.cr \
      -o "${log_dir}/sdk_reverse_commissioning_driver"
  ) 2>&1 | tee "${log_dir}/crystal-build.log"
fi

python3 "${repo_root}/e2e/interop/sdk_reverse_commissioning_live.py" \
  --sdk "${sdk_root}" \
  --aggregator "${MATTER_REVERSE_AGGREGATOR_BIN:-${log_dir}/matter_reverse_aggregator}" \
  --driver "${MATTER_REVERSE_DRIVER_BIN:-${log_dir}/sdk_reverse_commissioning_driver}" \
  --log-dir "${log_dir}" \
  --crystal-ip "${MATTER_REVERSE_CRYSTAL_IP:-fd42:4d41:5454::2}"
