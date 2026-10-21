#!/usr/bin/env bash
set -euo pipefail

# Linux x64 only: SDK target names and operational mDNS setup are platform specific.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
sdk_root="${MATTER_SDK_ROOT:-${repo_root}/tmp/connectedhomeip}"
log_dir="${MATTER_INTEROP_LOG_DIR:-${repo_root}/tmp/interop-sdk-jfc}"
sdk_tag="v1.6.0.0"

if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
  echo "This smoke test requires Linux x86_64" >&2
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
    # Neither Linux JF target needs Arm GCC. The stock SDK environment asks
    # CIPD to fetch it anyway, which has failed on constrained CI runners.
    python3 - <<'PY'
import json
from pathlib import Path

config = json.loads(Path("scripts/setup/environment.json").read_text())
config["cipd_package_files"] = [
    package for package in config["cipd_package_files"]
    if not package.endswith("/arm.json")
]
Path("objdir-jf-environment.json").write_text(json.dumps(config))
PY
    export PW_CONFIG_FILE=objdir-jf-environment.json
    # The SDK bootstrap script reads unset optional environment variables.
    # Restore nounset immediately afterward for the rest of this runner.
    set +u
    source scripts/bootstrap.sh -p linux
    set -u
    ./scripts/build/build_examples.py \
      --target linux-x64-jf-control-app-ipv6only-no-ble-no-wifi-clang \
      --target linux-x64-jf-admin-app-ipv6only-no-ble-no-wifi-clang \
      --build-profile debug \
      build --copy-artifacts-to objdir-jf
  ) 2>&1 | tee "${log_dir}/sdk-build.log"
fi

switch_bin="${MATTER_INTEROP_SWITCH_BIN:-${log_dir}/matter_switch}"
if [[ "${MATTER_INTEROP_SKIP_BUILD:-0}" != 1 ]]; then
  (cd "${repo_root}" && crystal build examples/matter_switch_device.cr -o "${switch_bin}") \
    2>&1 | tee "${log_dir}/switch-build.log"
fi

python3 "${repo_root}/e2e/interop/sdk_jfc_switch_smoke.py" \
  --sdk "${sdk_root}" --switch "${switch_bin}" --log-dir "${log_dir}"
