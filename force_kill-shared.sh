#!/usr/bin/env bash
# force_kill-shared.sh — variant of the stock force_kill.sh for a SHARED host.
#
# Differences from the stock free5GC force_kill.sh (and why):
#   * NO `sudo killall tcpdump`      — would kill any other user's packet capture on this host.
#   * NO `sudo rm /dev/mqueue/*`     — would delete every POSIX message queue on this host,
#                                      not just free5GC's.
#   * NO `-db` option                — the whole-database drop is removed outright so it cannot
#                                      be reached by a stray argument. Only the per-start
#                                      collections below are dropped, and only in DB "free5gc".
# Everything else is byte-faithful to force_kill.sh.
#
# Open5GS is unaffected: its binaries are named open5gs-<nf>d, and `killall` matches exact
# process names, so none of the names below can match them.

DB_NAME="free5gc"
DB_DROP_COLLECTION=(
    "NfProfile"
    "applicationData.influenceData.subsToNotify"
    "applicationData.subsToNotify"
    "policyData.subsToNotify"
    "exposureData.subsToNotify"
)

NF_LIST="nrf amf smf udr pcf udm nssf ausf bsf n3iwf upf chf nef tngf"

for NF in ${NF_LIST}; do
    sudo killall -9 ${NF} 2>/dev/null
done

sudo ip link del upfgtp 2>/dev/null
sudo ip link del ipsec0 2>/dev/null

# Clean test network environment created by test.sh
sudo ip link del veth0 2>/dev/null || true
sudo ip netns del UPFns 2>/dev/null || true
sudo ip addr del 10.60.0.1/32 dev lo 2>/dev/null || true

XFRMI_LIST=($(ip link | grep xfrmi | awk -F'[:,@]' '{print $2}'))
for XFRMI_IF in "${XFRMI_LIST[@]}"
do
    sudo ip link del $XFRMI_IF
done
sudo rm -f /tmp/free5gc_unix_sock
sudo rm -f cert/*_*
sudo rm -f test/cert/*_*
sudo rm -f /tmp/config.json # CHF ChargingGatway FTP config

MONGO_SCRIPT=""
for COLLECTION in "${DB_DROP_COLLECTION[@]}"
do
    MONGO_SCRIPT+="db.$COLLECTION.drop();"
done
if command -v mongosh &> /dev/null; then
    mongosh "$DB_NAME" --eval "$MONGO_SCRIPT"
else
    mongo "$DB_NAME" --eval "$MONGO_SCRIPT"
fi
