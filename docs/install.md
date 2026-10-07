# Installing free5GC v4.2.3 from source beside Open5GS

free5GC v4.2.3 built from source on Ubuntu 22.04, on a host that already runs Open5GS. Both
cores bind the same N2, N3 and N4 addresses, so exactly one of them runs at a time and a
switch script enforces that.

## Placeholders

Replace these throughout. Nothing in this repository contains real values.

| Placeholder | Meaning | Example shape |
| --- | --- | --- |
| `<CORE_HOST_IP>` | The host address both cores bind for N2, N3 and N4 | `10.0.0.5` |
| `<DATA_IFACE>` | Interface carrying UE traffic to the outside, for NAT | `eno1` |
| `<GNB_SUBNET>` | Subnet the gNB lives in, when it is not on `<CORE_HOST_IP>`'s link | `10.1.2.0/24` |
| `<GNB_ROUTE_VIA>` | Next hop towards `<GNB_SUBNET>` | `10.0.0.9` |
| `<GNB_PROBE_IP>` | One address inside `<GNB_SUBNET>`, used to test the route | `10.1.2.50` |
| `<INSTALL_DIR>` | Where this repository is cloned | `/home/<SERVICE_USER>/free5gc` |
| `<SERVICE_USER>` | Unprivileged user owning the clone and the Open5GS screen sessions | `core` |
| `<OPEN5GS_DIR>` | Existing Open5GS checkout | `/home/<SERVICE_USER>/open5gs` |
| `<OPEN5GS_START_SCRIPT>` | Existing script that starts Open5GS | `/home/<SERVICE_USER>/restart_open5gs.sh` |
| `<OPEN5GS_STOP_SCRIPT>` | Stop helper installed by this guide | `/home/<SERVICE_USER>/stop_open5gs.sh` |
| `<AMF_UUID>` | AMF NF instance ID, pinned so the NSSF can match it | any UUIDv4 |

`00101` (MCC `001`, MNC `01`) is the test PLMN used throughout. `10.60.0.0/16` is free5GC's UE
pool, chosen so it cannot overlap Open5GS's `10.45.0.0/16`.

## One core at a time

Open5GS and free5GC both need `<CORE_HOST_IP>:38412/sctp` (N2), `:2152/udp` (N3) and
`:8805/udp` (N4). Nothing lets them share those. `core-switch` is the only supported way to move
between them: it takes an flock, stops the other core, waits for the kernel to release the
sockets, starts the one you asked for, and verifies it. The kernel socket table is the
authority, not the process list and not any script's exit code.

Open5GS is the default. A host that has never switched, or has been rebooted, is on Open5GS.

## Hard rules

- **Never run `quick-setup.sh`.** It installs and reconfigures MongoDB and rewrites host
  networking. On a shared host it will take Open5GS down with it.
- **Never run `reload_host_config.sh`.** It adds a blanket MASQUERADE and disables the
  firewall. Use [Host networking](#host-networking) instead.
- **Never flush iptables** (`-F`, `-X`, `-P`). Other services own chains in the same tables.
  Every rule here is pool-scoped and added idempotently with `-C … || -A`.
- **Never pass `-db` to any force-kill script.** It drops the whole `free5gc` database,
  subscribers included. `force_kill-shared.sh` in this repository has the option removed.
- **Never `systemctl enable` the free5GC units.** A reboot must leave the host on Open5GS.

## Prerequisites

### Kernel and headers

`gtp5g` is a kernel module and needs headers for every kernel you might boot:

```bash
uname -r
dpkg -l | grep -E '^ii +linux-headers-[0-9]'
sudo apt-get install -y linux-headers-$(uname -r)
```

Install headers for each kernel listed by `dpkg -l | grep '^ii +linux-image-[0-9]'`, not only
the running one, or the module will be missing after a kernel upgrade reboots you into the other.

### Secure Boot

```bash
mokutil --sb-state
```

`SecureBoot disabled` means DKMS modules load unsigned. If it reports `SecureBoot enabled`, stop
here: you must enrol a Machine Owner Key and sign the module, which this guide does not cover.

### Packages

```bash
sudo apt-get update
sudo apt-get install -y libmnl-dev dkms
```

`dkms` pulls in `gcc-12` and its runtime libraries. That is wanted: Ubuntu 22.04's HWE 6.8
kernels are built with gcc-12, and the module compiles cleanly against them. `gcc-11` stays the
default `gcc`; nothing is reconfigured.

### Go 1.26.2

```bash
cd /tmp
curl -fsSLO https://dl.google.com/go/go1.26.2.linux-amd64.tar.gz
sha256sum go1.26.2.linux-amd64.tar.gz
#   990e6b4bbba816dc3ee129eaeaf4b42f17c2800b88a2166c265ac1a200262282
sudo tar -C /usr/local -xzf go1.26.2.linux-amd64.tar.gz
rm go1.26.2.linux-amd64.tar.gz
/usr/local/go/bin/go version          # go1.26.2 linux/amd64
```

Do not edit shell rc files. Builds below pass `PATH=/usr/local/go/bin:$PATH` explicitly, so the
toolchain cannot leak into other users' shells.

### MongoDB

Open5GS already runs MongoDB and free5GC uses the same server with a different database
(`free5gc` against Open5GS's `open5gs`). **Do not reinstall or upgrade it**: an Open5GS
install script run on a shared host drops the subscriber database.

```bash
systemctl is-active mongod            # active
mongosh --quiet --eval 'db.adminCommand({ping:1}).ok'    # 1
```

### Outbound access

| Host | Needed for |
| --- | --- |
| `github.com` | the clone and its 15 submodules |
| `proxy.golang.org` | Go module downloads during `make` |
| `dl.google.com` | the Go toolchain tarball |

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://github.com https://proxy.golang.org
```

## gtp5g through DKMS

Build from a copy under `/usr/src` so the source checkout stays untouched and DKMS owns the
tree:

```bash
git clone https://github.com/free5gc/gtp5g.git /tmp/gtp5g
cd /tmp/gtp5g && git checkout v0.10.2
sudo cp -a /tmp/gtp5g /usr/src/gtp5g-0.10.2
sudo rm -rf /usr/src/gtp5g-0.10.2/.git

sudo dkms add -m gtp5g -v 0.10.2
for k in $(ls /lib/modules); do
    sudo dkms build   -m gtp5g -v 0.10.2 -k "$k"
    sudo dkms install -m gtp5g -v 0.10.2 -k "$k"
done
dkms status
#   gtp5g/0.10.2, <kernel>, x86_64: installed      (one line per kernel)
```

Confirm it loads, then unload it:

```bash
sudo modprobe gtp5g
modinfo gtp5g | grep -E '^(filename|version|vermagic)'
#   vermagic must match `uname -r`
sudo rmmod gtp5g
```

**Do not auto-load it.** No entry in `/etc/modules-load.d/` or `/etc/modules`:

```bash
grep -rs gtp5g /etc/modules-load.d/ /etc/modules      # expect no match
```

The free5GC unit loads it in `ExecStartPre`, so it is present only while free5GC runs.

## Source and build

```bash
git clone --recursive -b v4.2.3 -j "$(nproc)" https://github.com/free5gc/free5gc.git <INSTALL_DIR>
cd <INSTALL_DIR>
git fetch --tags upstream 2>/dev/null || git fetch --tags origin
git describe --tags            # v4.2.3
git submodule status           # 15 entries, each at its tagged commit
```

HEAD is detached, which is correct for a pinned release. Fetch the tags: the build stamps its
version from `git describe`, and without them the binaries report an unknown version.

Build the NFs:

```bash
cd <INSTALL_DIR>
PATH=/usr/local/go/bin:$PATH make
ls bin/        # amf ausf bsf chf n3iwf nef nrf nssf pcf smf tngf udm udr upf
```

Use `make`, not `make all`. `make all` adds the test targets, which build a webconsole copy and
run against a test network namespace you do not want on a shared host.

### WebConsole

The backend is a separate target:

```bash
cd <INSTALL_DIR>
PATH=/usr/local/go/bin:$PATH make webconsole
ls -l webconsole/bin/webconsole
```

The frontend is a static bundle the backend serves from `webconsole/public`. Either build it:

```bash
sudo apt-get remove -y nodejs libnode-dev && sudo apt-get autoremove -y
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs
sudo corepack enable
cd <INSTALL_DIR>/webconsole/frontend
yarn install && yarn build
cp -r build ../public
```

or copy a prebuilt `public/` from another machine. Without it the REST API works and the browser
UI returns `404 page not found`.

The backend resolves `public` relative to its working directory
(`backend/webui_service/middleware.go`, `var PublicPath = "public"`), so the unit sets
`WorkingDirectory=<INSTALL_DIR>/webconsole` and passes the config absolutely with `-c`. The
config's `cert/chf.pem` is relative too, so link the certificate directory:

```bash
ln -s ../cert <INSTALL_DIR>/webconsole/cert
```

## Configuration

The four files in `config/` in this repository are already edited for a shared host; copy them
over the upstream ones and substitute the placeholders. If you start from upstream's files
instead, apply everything below.

### PLMN

`config/` in this repository already carries MCC `"001"` / MNC `"01"`, quoted, in the five
files the started NFs read: `amfcfg.yaml`, `ausfcfg.yaml`, `nrfcfg.yaml`, `nssfcfg.yaml` and
`smfcfg.yaml`. `n3iwfcfg.yaml` and `tngfcfg.yaml` keep upstream's `208`/`93`; neither NF is
started by `run.sh`'s default list (`nrf amf smf udr pcf udm nssf ausf chf nef`, plus the UPF).

For a different PLMN, edit those five by hand. Do not sed the value in: an unquoted
replacement produces the integer-coercion failure described next.

### Quote the PLMN and TAC

```yaml
  supportTaiList:
    - plmnId:
        mcc: "001"
        mnc: "01"
      tac: "000001"
```

Unquoted, YAML reads `mcc: 001` and `tac: 000001` as the integer `1`, while the gNB and NSSF
exchange the strings `"001"` and `"000001"`. The AMF then logs
`No TA {...tac:000001} in NSSF configuration` and registration fails.

### amfcfg.yaml

```yaml
configuration:
  nfInstanceId: <AMF_UUID>
  ngapIpList:
    - <CORE_HOST_IP>
  sbi:
    registerIPv4: 127.0.0.1
    bindingIPv4: 127.0.0.1
  plmnSupportList:
    - plmnId:
        mcc: "001"
        mnc: "01"
      snssaiList:
        - sst: 1
```

`nfInstanceId` must be pinned. free5GC generates a fresh UUID at every start otherwise, and the
NSSF's `amfList` cannot match a value that changes.

Generate one UUID and use that single value in **both** files, as `nfInstanceId` in
`amfcfg.yaml` and as the one entry of `amfList` in `nssfcfg.yaml`:

```bash
uuidgen            # e.g. 3f2b1c84-9d7e-4a15-b0c3-6e8f24a7d591
```

`snssaiList` must carry `sst: 1` with **no** `sd` beneath it. With an SD, the AMF logs
`RequestedNssai[{Sst:1 Sd:}] is not supported by AMF` for a UE that asks for a blank SD.

### smfcfg.yaml

```yaml
  userplaneInformation:
    upNodes:
      gNB1:
        type: AN
      UPF:
        type: UPF
        nodeID: <CORE_HOST_IP>
        addr: <CORE_HOST_IP>
        sNssaiUpfInfos:
          - sNssai:
              sst: 1
            dnnUpfInfoList:
              - dnn: internet
                pools:
                  - cidr: 10.60.0.0/16
        interfaces:
          - interfaceType: N3
            endpoints:
              - <CORE_HOST_IP>
```

The N3 endpoint defaults to a loopback address such as `127.0.0.8`, which no gNB can reach.

```yaml
  urrThreshold: 107374182400
```

Upstream asks the UPF for a usage report every `500000` bytes, which at a few hundred Mbit/s is
over a hundred reports a second, and the SMF clears each one by waiting for the CHF to write a
CDR: the reports queue faster than they drain, and the next PDU session for that subscriber waits
behind the queue rather than being set up. Raise the threshold on any host that carries a
throughput test; leave `urrPeriod` alone, so a periodic report still arrives every 30 s.

### upfcfg.yaml

```yaml
pfcp:
  addr: <CORE_HOST_IP>
  nodeID: <CORE_HOST_IP>

gtpu:
  forwarder: gtp5g
  ifList:
    - addr: <CORE_HOST_IP>
      type: N3
      mtu: 1400

dnnList:
  - dnn: internet
    cidr: 10.60.0.0/16
    natifname: <DATA_IFACE>
```

Three things bite here:

- Leaving `nodeID` as `upf.free5gc.org` crashes the UPF at startup with
  `NodeID[upf.free5gc.org] can't be resolved`.
- `mtu: 1400` matches Open5GS's `ogstun` default. free5GC defaults the `upfgtp` tunnel to 1464,
  which the GTP-U path cannot carry without fragmentation, and TCP through the tunnel stalls.
- `natifname` must sit under the `10.60.0.0/16` entry, the pool the UE actually gets. Under an
  unused pool, UE egress has no NAT.

### nssfcfg.yaml

Upstream ships 300-plus lines of foreign test networks. Replace with your PLMN, one TAI and one
NSI; see `config/nssfcfg.yaml` in this repository. The part that must agree with the AMF:

```yaml
  amfSetList:
    - amfSetId: 1
      amfList:
        - <AMF_UUID>
```

A mismatch produces `No AMF <uuid> in NSSF configuration` in the NSSF and
`can not select an target AMF by NRF` in the AMF.

### WebConsole bind

`config/webuicfg.yaml` here sets `webServer.ipv4Address: 127.0.0.1`. Upstream ships `0.0.0.0`,
which exposes the provisioning UI and its REST API on every interface.

### UE pool

Keep `10.60.0.0/16` distinct from Open5GS's `10.45.0.0/16`. Overlapping pools make a UE address
ambiguous: nothing downstream can tell which core assigned it.

Validate every file you edit before starting anything:

```bash
cd <INSTALL_DIR>/config
for f in *.yaml; do python3 -c "import yaml,sys; yaml.safe_load(open('$f'))" || echo "BAD $f"; done
```

## Host networking

The units apply the NAT and MSS rules on start and remove them on stop, so free5GC's rules exist
only while free5GC runs. Both are pool-scoped and idempotent:

```bash
iptables -t nat -C POSTROUTING -s 10.60.0.0/16 ! -o upfgtp -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s 10.60.0.0/16 ! -o upfgtp -j MASQUERADE

iptables -t mangle -C FORWARD -o upfgtp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
iptables -t mangle -A FORWARD -o upfgtp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
```

`! -o upfgtp` keeps tunnel-internal traffic out of the NAT. iptables stores `-o` by interface
name, so naming `upfgtp` before the UPF creates it is valid.

IP forwarding, persistently:

```bash
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-free5gc.conf
sudo sysctl --system
```

If the gNB is not on the same link as `<CORE_HOST_IP>`, the host needs a return route or
downlink is black-holed while uplink still works:

```bash
ip route get <GNB_PROBE_IP>        # must show via <GNB_ROUTE_VIA>, not the default gateway
sudo ip route replace <GNB_SUBNET> via <GNB_ROUTE_VIA> dev <DATA_IFACE>
```

Make that route permanent through your network configuration; `ip route` alone does not survive
a reboot.

## systemd units

Copy both units, reload, and confirm they are static:

```bash
sudo cp deploy/systemd/free5gc.service deploy/systemd/free5gc-webconsole.service \
        /etc/systemd/system/
sudo sed -i 's|<INSTALL_DIR>|/actual/path|g; s|<CORE_HOST_IP>|10.0.0.5|g' \
        /etc/systemd/system/free5gc.service /etc/systemd/system/free5gc-webconsole.service
sudo systemctl daemon-reload
systemctl is-enabled free5gc.service free5gc-webconsole.service    # static, static
systemd-analyze verify /etc/systemd/system/free5gc.service
```

Neither unit has an `[Install]` section, so neither can be enabled and neither starts at boot.
`core-switch` starts them explicitly.

`free5gc.service` runs `run.sh` with no flags, so no N3IWF, no TNGF, no BSF and no packet
capture. `ExecStop` is `force_kill-shared.sh`, this repository's variant of the stock
`force_kill.sh` with three removals: no `killall tcpdump`, no `rm /dev/mqueue/*`, and no `-db`
option. All three would reach beyond free5GC on a shared host.

Install the force-kill helper and the Open5GS stop helper:

```bash
cp force_kill-shared.sh <INSTALL_DIR>/
chmod +x <INSTALL_DIR>/force_kill-shared.sh

sudo cp deploy/scripts/stop_open5gs.sh <OPEN5GS_STOP_SCRIPT>
sudo chown root:root <OPEN5GS_STOP_SCRIPT>
sudo chmod 755 <OPEN5GS_STOP_SCRIPT>
```

## Coexisting with Open5GS

### The stop helper

`stop_open5gs.sh` and `core-switch` assume an Open5GS built from source, whose NFs run in screen
sessions under an SSH login scope where `systemctl stop` cannot reach them. A packaged Open5GS
runs as `open5gs-*.service` units and needs a different stop and start; replace the bodies of
both scripts accordingly.

`stop_open5gs.sh` is the contract:

- **exit 0** — `38412/sctp`, `<CORE_HOST_IP>:2152/udp` and `<CORE_HOST_IP>:8805/udp` are all free.
- **non-zero** — something still holds one of them, and the caller must not continue.

It sends `TERM` to the eleven `open5gs-*d` process names by exact match, waits, `KILL`s what is
left, quits the screen sessions as their owners, removes every copy of the Open5GS NAT rule,
deletes `ogstun`, then polls the socket table until all three are free.

It also refuses to run while a switch has selected free5GC:

```bash
if [ "${CORE_SWITCH_BYPASS:-}" != 1 ] && [ "$(cat /run/core-switch.state 2>/dev/null)" = free5gc ]; then
    log "ERROR: core-switch has selected free5GC; run: sudo core-switch open5gs"; exit 5
fi
```

Without it a scheduled Open5GS restarter would start Open5GS underneath a running free5GC and
fight it for the sockets. `CORE_SWITCH_BYPASS=1` is set only by `core-switch`, for its own stop;
a caller cannot set it, because `sudo`'s `env_reset` strips it.

### The switch

```bash
sudo cp deploy/scripts/core-switch /usr/local/bin/core-switch
sudo chown root:root /usr/local/bin/core-switch
sudo chmod 755 /usr/local/bin/core-switch
sudo sed -i 's|<INSTALL_DIR>|/actual/path|g; s|<CORE_HOST_IP>|10.0.0.5|g' /usr/local/bin/core-switch
sudo bash -n /usr/local/bin/core-switch
```

Edit the variables at the top of the script: `CORE_IP`, `FREE5GC_DIR`, `OPEN5GS_DIR`,
`OPEN5GS_STOP`, `OPEN5GS_START`, `OPEN5GS_USER`.

| Command | Effect |
| --- | --- |
| `sudo core-switch open5gs` | stop free5GC, start Open5GS |
| `sudo core-switch free5gc` | stop Open5GS, start free5GC |
| `sudo core-switch status` | `key=value` state dump, read-only |
| `sudo core-switch health` | status plus a health check of whichever core is up |

| Exit | Meaning |
| --- | --- |
| 0 | done, and verified |
| 1 | usage error, or not root |
| 2 | another switch holds the lock |
| 3 | the other core would not release the sockets |
| 4 | started, but never came up healthy |

Health re-evaluates every check together every 2 s for up to 60 s. One pass is not enough:
free5GC binds its sockets about a second before the SMF logs the PFCP association, so a
one-shot check reports a false failure.

### Calling it from automation

Install the sudoers rule so an unprivileged account can switch without a password, and only
through these four exact commands:

```bash
sudo cp deploy/sudoers/core-switch /etc/sudoers.d/core-switch
sudo sed -i 's|<SERVICE_USER>|actualuser|g' /etc/sudoers.d/core-switch
sudo chmod 440 /etc/sudoers.d/core-switch
sudo visudo -c -f /etc/sudoers.d/core-switch
```

Treat each exit code differently and **never retry**: `core-switch` holds a lock and verifies
the sockets itself, so a retry either queues behind the first attempt or races it. Assert the
core before every measurement, not once per session. `core-switch status` prints `core=` (which
core owns the sockets) and `selected=` (which was last asked for); they disagree exactly when a
switch stopped halfway.

Always switch back to Open5GS when finished, on success and on failure.

### Before the first switch

A switch drops every NGAP association on the core that is running. List them first, and agree a
window with whoever owns a gNB that is not yours:

```bash
ss -H -n -S state established 'sport = :38412'
```

## Subscribers

The WebConsole binds loopback only. Reach it over an SSH tunnel rather than exposing port 5000:

```bash
ssh -L 5000:127.0.0.1:5000 <SERVICE_USER>@<CORE_HOST_IP>
```

Open `http://127.0.0.1:5000/`, log in, and change the default password before anything else.

For each subscriber:

- PLMN `00101`, SUPI the IMSI, authentication `5G_AKA`
- K and OPc from the SIM
- **Delete the template slices first.** The default form offers slices with SD `010203` and
  `112233`. Add one slice, `SST 1`, **SD blank**, and make it the default. A UE that requests
  `{Sst:1 Sd:}` does not match a subscriber whose only slice carries an SD.
- DNN `internet`, and no other DNN
- 5QI `9`
- Session-AMBR at or above the rate you intend to measure, or the UPF polices below line rate
- Leave the static IPv4 address empty

Verify without reading key material:

```bash
mongosh --quiet free5gc --eval '
  const db1 = db.getSiblingDB("free5gc");
  print("subscribers:", db1.subscriptionData.provisionedData.amData.countDocuments({}));
  db1.subscriptionData.provisionedData.amData.find({}, {ueId:1, servingPlmnId:1, nssai:1, _id:0}).forEach(printjson);
  db1.subscriptionData.provisionedData.smfSelectionSubscriptionData.find({}, {ueId:1, subscribedSnssaiInfos:1, _id:0}).forEach(printjson);
  print("flowRule:", db1.policyData.ues.flowRule.countDocuments({}));
  print("qosFlow:",  db1.policyData.ues.qosFlow.countDocuments({}));
  print("auth docs:", db1.subscriptionData.authenticationData.authenticationSubscription.countDocuments({}));
'
```

Expect, per subscriber: `servingPlmnId` `00101`, exactly one S-NSSAI `{sst:1}` with no `sd` key,
DNN list `["internet"]`, and zero flow rules and QoS flows. The last line counts the
authentication documents without printing them. Never `find()` that collection: it holds K and
OPc.

If a save returns `401` with `ParseJWT error: token signature is invalid`, the browser holds a
token from before a WebConsole restart. Log out, log in, save again.

## Verification

```bash
sudo core-switch free5gc                 # expect exit 0, 15-20 s
sudo core-switch health                  # expect exit 0
sudo core-switch status
```

`status` reports `core=free5gc`, `selected=free5gc`, all three sockets owned by free5GC's `amf`
and `upf`, `gtp5g_loaded=yes`, and `upfgtp` present.

Point the gNB at `<CORE_HOST_IP>` and watch for NG Setup:

```
[AMF][Ngap] [AMF] SCTP Accept from: <gnb>:<port>
[AMF][Ngap] Handle NGSetupRequest
[AMF][Ngap] Send NG-Setup response
```

Attach a UE. A first attempt should succeed:

```
[AMF][Gmm] Handle event[ContextSetup Success], transition from [ContextSetup] to [Registered]
[AMF][Gmm] Select SMF [snssai: {Sst:1 Sd:}, dnn: internet]
[SMF][CTX] Allocated UE IP address: 10.60.0.1
[SMF][PduSess] Received PFCP Session Establishment Accepted Response
[AMF][Ngap] Handle PDUSessionResourceSetupResponse
```

The address must be inside `10.60.0.0/16`.

**The first attach after a switch resyncs the SIM's sequence number.** The counter advanced on
the other core, so the UE answers the first challenge with
`Authentication Failure 5GMM Cause: Synch Failure`; the UDM accepts the AUTS and the second
challenge succeeds about 100 ms later. Once per core. Discard that first timing sample.

**Never use the UE pool's first address as the core's data-plane address.** `10.60.0.1` is the
first address the SMF allocates to a UE, and `upfgtp` has no IPv4 address of its own. Use
`<CORE_HOST_IP>` as the core side of any measurement.

On a 1 GbE N3 link the ceiling is 941 Mbit/s, the same for both cores: both use `gtp5g`.
Compare cores at a matched offered rate and a matched loss point, never on headline numbers, or
an overdriven run at 13 % loss beats a clean one at under 1 %.

Finish by returning the host to Open5GS:

```bash
sudo core-switch open5gs
sudo core-switch health
```

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| free5GC start fails, `bind: address already in use` on 2152 | a previous run left `upfgtp` and the UPF socket behind | `sudo ip link del upfgtp`; confirm with `sudo ss -ulnp \| grep 2152`, then start again |
| `systemctl start free5gc` does nothing, `start request repeated too quickly` | three failed starts inside 120 s tripped `StartLimitBurst` | `sudo systemctl reset-failed free5gc.service`, then start. `core-switch` does this before every start |
| `ss -lnp \| grep 38412` finds nothing while the AMF is clearly up | N2 is SCTP, and `ss` does not list SCTP without `-S` | `ss -H -l -n -p -S 'sport = :38412'` |
| Open5GS NRF fails to start or answers nothing after a switch back | its SBI needs HTTP/2; a proxy or a downgraded client turns it into HTTP/1.1 | query it directly with `curl --http2-prior-knowledge`, and keep proxies off loopback |
| A glob in a shell script silently matches nothing and the script aborts | zsh's `nomatch` aborts on an unmatched glob where bash passes it through | run deployment commands under `bash`, not the login shell |
| UE registers, then `RequestedNssai[{Sst:1 Sd:}] is not supported by AMF` | the subscriber or `amfcfg.yaml` still carries an SD | remove the SD from the subscriber's slice and from `plmnSupportList`; both must be `sst: 1` alone |
| Repeats after the first get no PDU session; the UE registers but has no address; the AMF logs `CreateSmContextRequest ... context deadline exceeded` | a charging-report backlog in the SMF from the 500 kB `urrThreshold` | set `urrThreshold: 107374182400` in `smfcfg.yaml` |
| `No TA {...tac:000001} in NSSF configuration` | the TAC is unquoted and parsed as the integer `1` | quote `mcc`, `mnc` and `tac` in every file |
| `No AMF <uuid> in NSSF configuration` | the AMF's instance ID is generated fresh at each start | pin `nfInstanceId` in `amfcfg.yaml` and list the same UUID in the NSSF `amfList` |
| WebConsole answers the API but the browser shows `404 page not found` | `public/` is missing, or the working directory is wrong | build or copy `webconsole/public`, and keep `WorkingDirectory=<INSTALL_DIR>/webconsole` |
| UE attaches, uplink works, pages never finish loading | no return route to `<GNB_SUBNET>`, so downlink is black-holed | `ip route get <GNB_PROBE_IP>`; if it leaves via the default gateway, add the route |
| TCP through the tunnel stalls while ping works | the `upfgtp` MTU is 1464 | set `mtu: 1400` in `upfcfg.yaml` and confirm the MSS clamp rule is present |

## Uninstall

```bash
sudo core-switch open5gs                  # leave the host on Open5GS first
sudo core-switch health

sudo systemctl stop free5gc.service free5gc-webconsole.service
sudo rm -f /etc/systemd/system/free5gc.service /etc/systemd/system/free5gc-webconsole.service
sudo systemctl daemon-reload

sudo rm -f /usr/local/bin/core-switch /etc/sudoers.d/core-switch
sudo rm -f <OPEN5GS_STOP_SCRIPT>

sudo dkms remove -m gtp5g -v 0.10.2 --all
sudo rm -rf /usr/src/gtp5g-0.10.2
sudo rm -f /etc/sysctl.d/99-free5gc.conf

rm -rf <INSTALL_DIR>
```

The free5GC database is left in place. Drop it only if you are certain no subscriber there is
needed:

```bash
mongosh --quiet --eval 'db.getSiblingDB("free5gc").dropDatabase()'
```

Open5GS keeps its own database and is untouched by any step above. Confirm the host is where you
left it:

```bash
sudo core-switch status      # core=open5gs, selected=open5gs
lsmod | grep gtp5g           # no output
ip link show upfgtp          # does not exist
```
