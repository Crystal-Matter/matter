#!/bin/sh
# Supervises an example device binary inside its compose container, mirroring
# its output to a log file that the test runner (and the compose healthcheck)
# read to obtain the pairing code.
#
# Usage: E2E_DEVICE=matter_switch device-entrypoint.sh [args...]
#
# Restart protocol (the `tests` container has no docker socket, so restarts are
# requested through the shared /e2e/logs volume):
#
#   1. The runner creates the marker file `$E2E_LOG_DIR/<device>.restart`.
#   2. This script removes the marker and sends SIGTERM to the device, which
#      shuts down cleanly (flushing its storage) and exits.
#   3. `=== e2e restart <n> ===` is appended to `<device>.log` and the binary is
#      started again in the same working directory, so it reopens its storage
#      and comes up commissioned. The log is only truncated when the container
#      starts, so the pairing code stays in it and the healthcheck keeps passing.
#
# The device is only restarted after a marker was requested. If it exits on its
# own the container exits with the device's status, so crashes are not masked.
# SIGTERM/SIGINT (docker stop) are forwarded to the device and end the loop.
set -eu

name="${E2E_DEVICE:?E2E_DEVICE must name an example binary, e.g. matter_switch}"
binary="${E2E_BINARY:-$name}"

log_dir="${E2E_LOG_DIR:-/e2e/logs}"
log="$log_dir/$name.log"
restart_marker="$log_dir/$name.restart"
# Each device keeps its storage in its own working directory so a fresh
# container always starts un-commissioned, while an in-container restart
# finds the state written by the previous run.
state_dir="/e2e/state/$name"
# Seconds between checks for the restart marker.
poll_interval=1
# `tail -f` re-reads the log about once a second; give it that long to mirror
# the device's final lines to the container output before exiting.
mirror_flush_delay=1

mkdir -p "$log_dir" "$state_dir"
: > "$log"
rm -f "$restart_marker"
if [ "${E2E_INTERFACE_SNAPSHOT:-0}" = "1" ]; then
  cp /proc/net/if_inet6 "$log_dir/$name.if_inet6"
fi
cd "$state_dir"

# Mirror the log to the container's stdout (docker compose logs). The device
# writes to the file directly so `wait` returns its real pid and exit status.
tail -n +1 -f "$log" &
mirror_pid=$!

device_pid=""
stopping=0

stop() {
  stopping=1
  if [ -n "$device_pid" ]; then
    kill -TERM "$device_pid" 2>/dev/null || true
  fi
}
trap stop TERM INT

restarts=0
status=0
while :; do
  "/app/bin/$binary" --no-interactive "$@" </dev/null >>"$log" 2>&1 &
  device_pid=$!

  # Watcher for this run: exits 0 once it has consumed a restart marker and
  # told the device to stop; it is killed (non-zero status) otherwise.
  (
    while [ ! -e "$restart_marker" ]; do
      sleep "$poll_interval"
    done
    rm -f "$restart_marker"
    kill -TERM "$device_pid" 2>/dev/null || true
  ) &
  watcher_pid=$!

  status=0
  wait "$device_pid" || status=$?
  # A trapped signal interrupts `wait` with a status above 128 before the
  # device has exited; wait again for its real exit status.
  while [ "$stopping" -eq 1 ] && [ "$status" -gt 128 ]; do
    status=0
    wait "$device_pid" || status=$?
  done

  kill "$watcher_pid" 2>/dev/null || true
  requested=0
  if wait "$watcher_pid"; then
    requested=1
  fi

  if [ "$stopping" -eq 1 ] || [ "$requested" -eq 0 ]; then
    break
  fi

  restarts=$((restarts + 1))
  echo "=== e2e restart $restarts ===" >>"$log"
done

sleep "$mirror_flush_delay"
kill "$mirror_pid" 2>/dev/null || true
exit "$status"
