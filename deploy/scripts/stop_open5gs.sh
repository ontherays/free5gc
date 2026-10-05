#!/bin/bash
# <OPEN5GS_STOP_SCRIPT> — stop Open5GS and PROVE the core sockets are free.
#
# INVOCATION
#   sudo <OPEN5GS_STOP_SCRIPT>            (how restart_open5gs.sh:53 calls it)
#   Takes no arguments. Must run as root. The path is fixed: the sudoers rule
#   whitelists exactly <OPEN5GS_STOP_SCRIPT>.
#
# CONTRACT
#   exit 0  -> 38412/sctp, <CORE_HOST_IP>:2152/udp and <CORE_HOST_IP>:8805/udp are ALL free.
#   exit !=0 -> something is still holding one of them. restart_open5gs.sh runs with
#              `set -e`, so a non-zero exit here ABORTS the restart instead of letting
#              the start phase fail halfway at `ip tuntap add name ogstun`.
#
# DELIBERATELY NOT DONE HERE
#   * No IP address is removed. An address configured by the Open5GS start script may be
#     the N2 source of a gNB that is still running; tearing it down on every core stop
#     would break that gNB. The start script manages its own addresses.
#   * Only the eleven NF process names below are touched. Any other screen session,
#     including ones belonging to other users, is left alone.

set -uo pipefail          # NOT -e: every step below is individually tolerant and checked.

CORE_IP=<CORE_HOST_IP>
NF_LIST=(nrf scp udr udm ausf pcf bsf nssf amf smf upf)
OWNER=<SERVICE_USER>                 # the user whose /run/screen/S-<user> holds the 10 NF sessions
TERM_WAIT=10              # seconds to wait for a graceful exit before SIGKILL
FREE_WAIT=15              # seconds to wait for the kernel to release the sockets

log() { printf '%s %s\n' "$(date -Is)" "$*"; }

[ "$(id -u)" -eq 0 ] || { log "ERROR: must run as root (invoke via sudo)"; exit 1; }

# Refuse to tear Open5GS down when core-switch has selected free5GC. This runs BEFORE any
# other action, so a scheduled restarter that calls restart_open5gs.sh cannot interleave with
# a switch in flight. restart_open5gs.sh runs under `set -e`, so this non-zero exit aborts it.
# CORE_SWITCH_BYPASS=1 is set ONLY by core-switch for its own stop, which must be able to
# tear Open5GS down after it has already recorded free5gc as the selected core.
if [ "${CORE_SWITCH_BYPASS:-}" != 1 ] && [ "$(cat /run/core-switch.state 2>/dev/null)" = free5gc ]; then
    log "ERROR: core-switch has selected free5GC; run: sudo core-switch open5gs"; exit 5
fi

# ---------------------------------------------------------------- socket probes
# The kernel socket table is the authority on "is the core down", not the process list.
n2_held() { [ -n "$(ss -H -l -S  "sport = :38412"           2>/dev/null)" ]; }
n3_held() { [ -n "$(ss -H -l -u  "src ${CORE_IP}:2152"      2>/dev/null)" ]; }
n4_held() { [ -n "$(ss -H -l -u  "src ${CORE_IP}:8805"      2>/dev/null)" ]; }
sockets_free() { ! n2_held && ! n3_held && ! n4_held; }

log "=== Stopping Open5GS ==="

# ---------------------------------------------------------------- 1. graceful TERM
# Exact process names only (pkill -x), so nothing else on this shared host is hit.
# free5GC's binaries are amf/smf/upf/... with no open5gs- prefix: they cannot match.
for nf in "${NF_LIST[@]}"; do
    pkill -x -TERM "open5gs-${nf}d" 2>/dev/null && log "  TERM open5gs-${nf}d"
done

# ---------------------------------------------------------------- 2. wait, then KILL
for _ in $(seq 1 "$TERM_WAIT"); do
    still=0
    for nf in "${NF_LIST[@]}"; do pgrep -x "open5gs-${nf}d" >/dev/null 2>&1 && still=1; done
    [ "$still" -eq 0 ] && break
    sleep 1
done

for nf in "${NF_LIST[@]}"; do
    if pgrep -x "open5gs-${nf}d" >/dev/null 2>&1; then
        log "  KILL open5gs-${nf}d (did not exit within ${TERM_WAIT}s)"
        pkill -x -KILL "open5gs-${nf}d" 2>/dev/null
    fi
done

# The UPF runs as: screen -> sudo -> sudo -> open5gs-upfd. Killing the daemon leaves the
# two sudo wrappers to exit on their own; sweep them by exact path to be certain.
pkill -KILL -f '^sudo <OPEN5GS_DIR>/build/src/upf/open5gs-upfd' 2>/dev/null

# ---------------------------------------------------------------- 3. quit screens
# The sockets are SPLIT: /run/screen/S-<SERVICE_USER> holds the 10 NF sessions, /run/screen/S-root
# holds "upf" (it was created with `sudo screen`). A single user cannot reach both, so
# do each as its owner. A session whose command has already exited is gone anyway; this
# only clears stale sockets.
for s in "${NF_LIST[@]}"; do
    [ "$s" = upf ] && continue
    runuser -u "$OWNER" -- screen -X -S "$s" quit 2>/dev/null
done
screen -X -S upf quit 2>/dev/null          # we are root: this reaches S-root
runuser -u "$OWNER" -- screen -wipe >/dev/null 2>&1
screen -wipe >/dev/null 2>&1

# ---------------------------------------------------------------- 4. NAT cleanup
# Remove EVERY copy of the UE-pool MASQUERADE rule, not just one. iptables -D removes a
# single matching rule per call, so loop until it reports no match (bounded, never spins).
removed=0
while iptables -t nat -C POSTROUTING -s 10.45.0.0/16 ! -o ogstun -j MASQUERADE 2>/dev/null; do
    iptables -t nat -D POSTROUTING -s 10.45.0.0/16 ! -o ogstun -j MASQUERADE 2>/dev/null || break
    removed=$((removed + 1))
    [ "$removed" -ge 20 ] && { log "  WARNING: stopped after 20 deletions"; break; }
done
log "  removed ${removed} copy/copies of the 10.45.0.0/16 MASQUERADE rule"

# ---------------------------------------------------------------- 5. tunnel teardown
# Idempotent, and harmless when restart_open5gs.sh:69-71 repeats it. Doing it HERE is what
# lets `ip tuntap add name ogstun` at restart_open5gs.sh:103 (which has no `|| true` and
# would abort the script under `set -e`) succeed reliably.
ip link delete ogstun  2>/dev/null && log "  deleted ogstun"
ip link delete vrf-ogs 2>/dev/null
ip netns delete core-ns 2>/dev/null

# ---------------------------------------------------------------- 6. verify
for _ in $(seq 1 "$FREE_WAIT"); do sockets_free && break; sleep 1; done

if ! sockets_free; then
    log "ERROR: core sockets still held after ${FREE_WAIT}s:"
    n2_held && { log "  38412/sctp:";              ss -l -S -p "sport = :38412"      | sed 's/^/    /'; }
    n3_held && { log "  ${CORE_IP}:2152/udp:";     ss -l -u -p "src ${CORE_IP}:2152" | sed 's/^/    /'; }
    n4_held && { log "  ${CORE_IP}:8805/udp:";     ss -l -u -p "src ${CORE_IP}:8805" | sed 's/^/    /'; }
    log "  (if these are free5GC's amf/upf, run: core-switch open5gs)"
    exit 3
fi

log "=== Open5GS stopped; 38412/sctp, ${CORE_IP}:2152/udp, ${CORE_IP}:8805/udp are free ==="
exit 0
