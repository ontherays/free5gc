# free5GC v4.2.3, built from source, sharing a host with Open5GS

free5GC v4.2.3 with its 15 submodules pinned to the upstream tag, plus the configuration,
systemd units and scripts needed to run it on an Ubuntu 22.04 host that already runs Open5GS.

Both cores bind the same N2, N3 and N4 addresses, so only one runs at a time. A switch script
stops one, starts the other, and verifies the sockets actually moved. Open5GS is the default
and the host is returned to it when free5GC work finishes.

**[docs/install.md](docs/install.md)** is the installation guide: prerequisites, the `gtp5g`
DKMS module, the build, the configuration that differs from upstream, host networking, the
units, the switch, subscriber provisioning, verification and troubleshooting.

## Layout

| Path | Contents |
| --- | --- |
| `config/` | `amfcfg.yaml`, `smfcfg.yaml`, `upfcfg.yaml` and `nssfcfg.yaml`, edited for a shared host. Every other file is upstream's. |
| `deploy/systemd/` | `free5gc.service` and `free5gc-webconsole.service`. Static units, never enabled, started only by the switch script. |
| `deploy/scripts/` | `core-switch`, which enforces one core at a time, and `stop_open5gs.sh`, which stops Open5GS and proves the sockets are free. |
| `deploy/sudoers/` | The sudoers rule allowing an unprivileged account to run `core-switch` and nothing else. |
| `docs/` | The installation guide. |
| `force_kill-shared.sh` | Stops free5GC without touching anything else on the host: no `killall tcpdump`, no `rm /dev/mqueue/*`, no database drop. |

Everything else is free5GC v4.2.3 as released.

Host-specific values are placeholders such as `<CORE_HOST_IP>` and `<INSTALL_DIR>`, listed in a
table at the top of the guide.

## Upstream

free5GC is developed by the [free5GC project](https://free5gc.org) and is licensed under the
Apache License 2.0; see [LICENSE](LICENSE). This repository is a pinned build of
[free5gc/free5gc](https://github.com/free5gc/free5gc) at tag `v4.2.3` with deployment material
added. The NF source is unmodified.
