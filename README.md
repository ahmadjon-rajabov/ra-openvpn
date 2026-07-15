# RA OpenVPN — Remote Access VPN for the Isolated QCNets Lab

> **Status:** 🚧 Work in progress — Docker Compose scaffolding & host tooling complete; OpenVPN `server.conf` and first end-to-end connection are next.
> **Last updated:** 2026-07-15

A Dockerized, TCP-based OpenVPN **remote-access** server, deployed on the workstation `192.168.7.20`, exposed through Router 1's WAN (NAT-forwarded by the Omada SDN Controller), designed to coexist with an existing OpenVPN on Router 3.

---

## 📚 Table of Contents

1. [Motivation & Goals](#motivation--goals)
2. [Network Topology](#network-topology)
3. [Existing (Coworker) VPNs — Do Not Touch](#existing-coworker-vpns--do-not-touch)
4. [Design Decisions](#design-decisions)
5. [Project Layout](#project-layout)
6. [Prerequisites](#prerequisites)
7. [Configuration (`.env`)](#configuration-env)
8. [Docker Compose Stack](#docker-compose-stack)
9. [Router 1 (Omada SDN) NAT Rule](#router-1-omada-sdn-nat-rule)
10. [Host Firewall (UFW)](#host-firewall-ufw)
11. [Management Scripts](#management-scripts)
12. [Deployment Runbook](#deployment-runbook)
13. [Reachability Test Results](#reachability-test-results)
14. [Progress Checklist](#progress-checklist)
15. [Roadmap / TODO](#roadmap--todo)
16. [Troubleshooting](#troubleshooting)

---

## Motivation & Goals

The QCNets lab operates an **isolated 3-router network** that must be reachable remotely by team members for development, testing, and management of the SDN controller. Currently:

- A OpenVPN runs on **Router 3** (standalone, TCP/443).
- Another OpenVPN runs on the workstation `192.168.7.20` (TCP/1194) — not fully functional.
- The setup is fragile, undocumented, and not integrated with the Omada SDN Controller.

**Objectives for this project:**

- ✅ Deploy an independent OpenVPN service without disrupting existing ones.
- ✅ Fully containerized (Docker Compose), with a Web UI for user/certificate management.
- ✅ Env-driven configuration — no hardcoded values.
- ✅ Schema-based pre-flight validation.
- ✅ Route through an **Omada-SDN-managed router** (Router 1) so the setup is integrated with the SDN control plane.
- 🔜 Eventually replace the Router 3 OpenVPN entirely and add Router 3 to the SDN.
- ✅ Split-tunnel: only the private LAN subnets flow through the VPN; user internet traffic is unaffected.
- ✅ Only TCP (university firewall blocks UDP outbound); only ports 22 / 80 / 443 TCP allowed inbound to the isolated network.

---

## Network Topology

```
                    ┌────────────────┐
                    │  Remote User   │
                    │  (home / etc.) │
                    └────────┬───────┘
                             │
                             ▼
                    ┌────────────────┐
                    │    eduVPN      │  (only 22/80/443 TCP allowed
                    │  (university)  │   outbound after connection)
                    └────────┬───────┘
                             │
                             ▼
     ┌───────────────────────┴────────────────────────────┐
     │                University Network                  │
     │                                                    │
     │   Router 1 WAN    Router 2 WAN    Router 3 WAN     │
     │   172.31.54.28    172.31.54.??    172.31.54.20     │
     └───────┬──────────────────┬───────────────┬────────┘
             │                  │               │
     ┌───────▼─────────┐  ┌─────▼───────┐  ┌───▼─────────┐
     │   Router 1      │  │  Router 2   │  │  Router 3   │
     │   192.168.5.1   │  │ 192.168.6.1 │  │ 192.168.7.1 │
     │   (Omada SDN)   │  │ (Omada SDN) │  │ (Standalone)│
     │                 │  │             │  │  QuantumEdge│
     │   [NAT 443→     │  │             │  │   OpenVPN   │
     │    192.168.7.20 │  │             │  │   :443/tcp  │
     │    :1195]       │  │             │  │ 10.7.0.0/24 │
     └───────┬─────────┘  └─────┬───────┘  └───┬─────────┘
             │                  │              │
             └────── WireGuard site-to-site mesh (all 3) ──────┘
                                │
                    ┌───────────▼──────────────┐
                    │   Workstation            │
                    │   192.168.7.20 (eno1)    │
                    │   Debian 12 (bookworm)   │
                    │                          │
                    │   Docker containers:     │
                    │   • Omada SDN Controller │
                    │   • Coworker's OpenVPN   │
                    │     :1194/tcp            │
                    │     10.8.0.0/24          │
                    │   • RA OpenVPN (NEW)     │
                    │     :1195/tcp            │
                    │     10.99.99.0/24        │
                    │   • RA OpenVPN UI        │
                    │     :8045/tcp            │
                    └──────────────────────────┘
```

**Traffic path when a remote user connects:**

```
Client → eduVPN → University → Router 1 WAN :443
                             ↳ NAT-forward to 192.168.7.20:1195
                                            ↳ OpenVPN container
                                                    ↳ tun0 (10.99.99.0/24)
                                                            ↳ NAT-MASQUERADE
                                                            → 192.168.7.20/eno1
                                                            → WG mesh
                                                            → 192.168.5.0/24
                                                                 6.0/24
                                                                 7.0/24
```

---

## Existing VPNs — Do Not Touch

Two pre-existing OpenVPN services must be avoided:

| Where | Port | Protocol | Client Subnet | Notes |
|---|---|---|---|---|
| Router 3 (standalone Omada) | `443/tcp` | TCP | `10.7.0.0/24` | Named `QuantumEdge` in Omada UI. Full-tunnel mode. Working. |
| Workstation `192.168.7.20` | `1194/tcp` | TCP | `10.8.0.0/24` | Bare-metal `openvpn.service`. Not fully functional. |

**Our project must not collide with either.** We use different port, subnet, and container names.

---

## Design Decisions

| Concern | Chosen Value | Rationale |
|---|---|---|
| Location | Workstation `192.168.7.20`, containerized | Central management; Docker already used for SDN |
| Container base | `d3vilh/openvpn-server` + `d3vilh/openvpn-ui` | Open-source, web UI for user/cert management |
| Local port | `1195/tcp` | Coworker uses `1194/tcp` on same host |
| External port | `443/tcp` on Router 1 WAN | Only 22/80/443 TCP inbound at university |
| Protocol | TCP only | University firewall drops UDP |
| VPN client subnet | `10.99.99.0/24` | Doesn't collide with 10.7.0.0/24, 10.8.0.0/24, or any 192.168.x LAN |
| Tunneling mode | Split-tunnel | Coexists with user's eduVPN; only push routes for LAN subnets |
| Pushed routes | `192.168.5.0/24`, `192.168.6.0/24`, `192.168.7.0/24` | Full lab access via WG mesh |
| Reverse routing | NAT masquerade on workstation | Zero router-side config; VPN clients appear as `192.168.7.20` on lab LANs |
| UI access | UI bound only to `127.0.0.1` + `192.168.7.20` | Never exposed to the internet |
| Configuration | `.env` file, schema-validated | Single source of truth, no secrets in repo |
| Naming prefix | `ra-` (Remote Access) | Room for future VPN services on the same host |

---

## Project Layout

```
/opt/ra-openvpn/
├── .env                    # Actual config (chmod 600, gitignored)
├── .env.example            # Template for documentation
├── .gitignore              # Excludes secrets and runtime data
├── docker-compose.yaml     # Two services: ra-openvpn + ra-openvpn-ui
├── server.conf             # OpenVPN server config (Stage 3 — pending)
│
├── ra-ovpn.sh              # Container lifecycle → /usr/local/bin/ra-ovpn
├── ra-validate.sh          # Schema-driven .env validator → /usr/local/bin/ra-validate
├── ra-firewall.sh          # UFW/iptables host rules → /usr/local/bin/ra-firewall
│
├── pki/                    # Auto-populated by container (CA, certs, DH, TA)
├── clients/                # Client .ovpn files (created via UI)
├── config/                 # Extra client-specific configs
├── staticclients/          # Static IP overrides
├── log/                    # OpenVPN logs
└── db/                     # Web UI SQLite database
```

### Symlinks in `/usr/local/bin`

```bash
ra-ovpn      → /opt/ra-openvpn/ra-ovpn.sh
ra-validate  → /opt/ra-openvpn/ra-validate.sh
ra-firewall  → /opt/ra-openvpn/ra-firewall.sh
```

Created with:
```bash
sudo ln -s /opt/ra-openvpn/ra-ovpn.sh     /usr/local/bin/ra-ovpn
sudo ln -s /opt/ra-openvpn/ra-validate.sh /usr/local/bin/ra-validate
sudo ln -s /opt/ra-openvpn/ra-firewall.sh /usr/local/bin/ra-firewall
```

---

## Prerequisites

Host: `192.168.7.20` — Debian 12 (bookworm), Docker + Compose plugin installed, UFW enabled.

Confirmed at deployment time:

| Requirement | Verified How |
|---|---|
| IPv4 forwarding enabled | `sysctl net.ipv4.ip_forward` = `1` |
| Can reach Router 1 LAN | `ping 192.168.5.1` succeeds via `192.168.7.1` |
| WireGuard mesh healthy | `ip route get 192.168.5.1` shows `via 192.168.7.1` |
| Docker running | `docker --version` |
| No collisions | Coworker's ports/subnets documented above |

---

## Configuration (`.env`)

All configuration lives in `/opt/ra-openvpn/.env` — validated by `ra-validate.sh`.

Copy the template and edit:
```bash
cp .env.example .env
sudo chmod 600 .env
sudo chown root:root .env
nano .env
```

Full variable reference (defined in `SCHEMA` inside `ra-validate.sh`):

| Variable | Type | Example |
|---|---|---|
| `COMPOSE_PROJECT_NAME` | string | `ra-openvpn` |
| `RA_OPENVPN_CONTAINER_NAME` | string | `ra-openvpn` |
| `RA_OPENVPN_UI_CONTAINER_NAME` | string | `ra-openvpn-ui` |
| `RA_OPENVPN_IMAGE` | image | `d3vilh/openvpn-server:latest` |
| `RA_OPENVPN_UI_IMAGE` | image | `d3vilh/openvpn-ui:latest` |
| `RA_OPENVPN_HOST_PORT` | port | `1195` |
| `RA_OPENVPN_CONTAINER_PORT` | port | `1194` |
| `RA_OPENVPN_PROTO` | protocol | `tcp` |
| `RA_OPENVPN_UI_BIND_LOCAL` | ip | `127.0.0.1` |
| `RA_OPENVPN_UI_BIND_LAN` | ip | `192.168.7.20` |
| `RA_OPENVPN_UI_PORT` | port | `8045` |
| `RA_OPENVPN_ADMIN_USERNAME` | string | `admin` |
| `RA_OPENVPN_ADMIN_PASSWORD` | secret | *(strong password)* |
| `RA_TRUST_SUB` | cidr | `10.0.0.0/8` |
| `RA_GUEST_SUB` | cidr | `172.16.0.0/12` |
| `RA_HOME_SUB` | cidr | `192.168.0.0/16` |
| `RA_VPN_CLIENT_SUBNET` | cidr | `10.99.99.0/24` |
| `RA_LAN_INTERFACE` | iface | `eno1` |
| `RA_UI_ALLOWED_SUBNETS` | string | `"192.168.5.0/24 192.168.6.0/24 192.168.7.0/24 10.99.99.0/24"` |
| `RA_DOCKER_NET_NAME` | string | `ra_openvpn_net` |
| `RA_DOCKER_NET_SUBNET` | cidr | `172.20.0.0/24` |
| `RA_RESTART_POLICY` | string | `unless-stopped` |

**Validation types:** `port` (1-65535), `protocol` (tcp only), `cidr` (x.x.x.x/y), `ip` (x.x.x.x), `iface` (must exist on host via `ip link`), `secret` (must not be placeholder), `image` (image-reference format), `string` (anything non-empty).

---

## Docker Compose Stack

Two services defined in `docker-compose.yaml`:

- **`ra-openvpn`** — the OpenVPN daemon; publishes `${RA_OPENVPN_HOST_PORT}` on the host; `NET_ADMIN` capability + `privileged` for TUN.
- **`ra-openvpn-ui`** — the Beego-based Web UI; bound to loopback + LAN IP only; talks to the OpenVPN container via a shared docker bridge and the `pki/` volume.

Both share the docker bridge network `${RA_DOCKER_NET_NAME}` (`172.20.0.0/24`).

Bind-mounted volumes preserve state across container recreation.

---

## Router 1 (Omada SDN) NAT Rule

Configured via the Omada SDN Controller Web UI at `https://192.168.7.20:8043`.

**Path:** *Settings → Transmission → NAT → Virtual Servers*

**Rule:**

| Field | Value |
|---|---|
| Name | `RA-OpenVPN` |
| Interface | `2.5G WAN/LAN1` |
| External Port | `443` |
| Internal Server IP | `192.168.7.20` |
| Internal Port | `1195` |
| Protocol | `TCP` |
| Status | Enabled |

⚠️ **NAT Loopback caveat:** many TP-Link routers don't support hairpinning. Test the WAN IP from **outside** (via eduVPN), not from inside the LAN.

---

## Host Firewall (UFW)

Rules are applied by `ra-firewall.sh apply`. They are:

1. **Allow inbound** `${RA_OPENVPN_HOST_PORT}/tcp` from anywhere.
2. **Allow inbound** `${RA_OPENVPN_UI_PORT}/tcp` from `${RA_UI_ALLOWED_SUBNETS}` only.
3. **NAT masquerade** `${RA_VPN_CLIENT_SUBNET}` → `${RA_LAN_INTERFACE}` (added to `/etc/ufw/before.rules` in a tagged block).
4. `DEFAULT_FORWARD_POLICY="ACCEPT"` in `/etc/default/ufw`.
5. Persistent `net.ipv4.ip_forward=1` via `/etc/sysctl.d/99-ra-openvpn.conf`.

All rules are tagged `ra-openvpn` in UFW comments for easy audit/removal.

Preview / apply / remove:
```bash
sudo ra-firewall status
sudo ra-firewall apply
sudo ra-firewall remove
```

---

## Management Scripts

### `ra-ovpn` — Stack lifecycle

```
Usage:  ra-ovpn <command> [--no-validate]
```

Commands (auto-validate: up, restart, update): up Validate + start the stack (detached) down Stop and remove containers restart Validate + restart both containers logs [svc] Follow logs (svc: ra-openvpn | ra-openvpn-ui) status Show container status validate Run pre-flight validation only pull Pull latest images update Validate + pull + restart shell [svc] Open shell in container (default: ra-openvpn) dir Print the project directory help Show this help
Flags: --no-validate Skip validation (use with caution)


### `ra-validate` — Pre-flight config check

Schema-driven, four steps:
1. Required files exist.
2. Every schema variable is present and non-empty in `.env`.
3. Values pass type-specific validators (ports, CIDRs, interfaces, ...).
4. `docker compose config -q` parses the file cleanly.

Exit codes: `0` = pass, `1` = validation failed, `2` = script setup problem.

### `ra-firewall` — Host firewall manager

```
Usage: sudo ra-firewall <apply|remove|status>
```

Idempotent (safe to re-run). Rules are tagged `ra-openvpn`.

---

## Deployment Runbook

### First-time deployment

```bash
# 1. Clone / copy project to /opt/ra-openvpn
sudo mkdir -p /opt/ra-openvpn
# (copy files in)
# 2. Configure secrets
cd /opt/ra-openvpn sudo cp .env.example .env 
sudo nano .env 
# set RA_OPENVPN_ADMIN_PASSWORD etc. sudo chmod 600 .env sudo 
chown root:root .env
# 3. Symlink helpers
sudo chmod +x ra-*.sh 
sudo ln -sf /opt/ra-openvpn/ra-ovpn.sh /usr/local/bin/ra-ovpn 
sudo ln -sf /opt/ra-openvpn/ra-validate.sh /usr/local/bin/ra-validate 
sudo ln -sf /opt/ra-openvpn/ra-firewall.sh /usr/local/bin/ra-firewall
# 4. Validate config
ra-validate
# 5. Apply firewall
sudo ra-firewall apply
# 6. Start the stack (once server.conf is in place — see TODO)
ra-ovpn up
# 7. Follow logs to confirm PKI generation
ra-ovpn logs ra-openvpn
```
#### 8. Create first user via UI at http://192.168.7.20:8045

### Add/remove Router 1 NAT rule

Only through the Omada SDN Controller — see section above.

### Regenerate a client cert

Via the Web UI (`http://192.168.7.20:8045`) → Certificates → New.

---

## Reachability Test Results

Recorded during initial planning (2026-07-15):

| Test | Command | Result |
|---|---|---|
| Router 1 WAN reachable from eduVPN (before NAT rule) | `curl -v http://172.31.54.28` | ❌ Timed out |
| Router 3 WAN reachable from eduVPN | `curl -v http://172.31.54.20` | ✅ Connection refused (TCP handshake OK) |
| Router 1 WAN reachable after test NAT rule | `nc -vz 172.31.54.28 443` | ✅ Connection succeeded |
| Ping Router 1 LAN from workstation | `ping 192.168.5.1` | ✅ 1.8 ms |
| Route to `192.168.5.1` | `ip route get 192.168.5.1` | ✅ via `192.168.7.1` |

**Conclusion:** Router 1's WAN is reachable via eduVPN **when a NAT rule is present**. Option 2 (parallel to coworker's Router 3 setup) is viable.

---

## Progress Checklist

### ✅ Done

- [x] Requirements gathered; coworker's VPN details documented
- [x] Reachability of Router 1 WAN from eduVPN verified
- [x] Design decisions locked in (see table above)
- [x] Directory layout `/opt/ra-openvpn/` created
- [x] `.env.example` + `.env` (chmod 600) created
- [x] `docker-compose.yaml` written, env-driven
- [x] `ra-ovpn.sh` (lifecycle) written + symlinked
- [x] `ra-validate.sh` (schema-driven pre-flight) written + tested
- [x] `ra-firewall.sh` (UFW/NAT/forwarding) written
- [x] Router 1 NAT test rule verified via `nc -vz`

### 🚧 In Progress

- [ ] `server.conf` — currently empty (0 bytes)
- [ ] `ra-firewall apply` — not yet applied
- [ ] Router 1 permanent NAT rule (`443/tcp → 192.168.7.20:1195`) — needs to replace the test rule
- [ ] First stack startup (`ra-ovpn up`)
- [ ] First client `.ovpn` file generated and tested end-to-end

### 🎯 Future

- [ ] Pin Docker image versions in `.env` (drop `:latest`)
- [ ] Move Web UI behind HTTPS + reverse proxy
- [ ] Add Router 3 to Omada SDN
- [ ] Retire coworker's Router 3 OpenVPN and workstation :1194 OpenVPN
- [ ] Migrate all users to the new certs
- [ ] Static public IP from university IT — replaces manual WAN IP tracking

---

## Roadmap / TODO

### Stage 3 (next) — OpenVPN `server.conf`
Compose file server-side directives, pushed routes, TLS-crypt, split-tunnel setup.

### Stage 4 — First launch
`ra-firewall apply` → `ra-ovpn up` → PKI auto-generation → confirm `1195/tcp` listening.

### Stage 5 — Permanent Router 1 NAT rule
Delete the test rule; add the production rule per the [Router 1 (Omada SDN) NAT Rule](#router-1-omada-sdn-nat-rule) section.

### Stage 6 — First client
Create a user via UI → download `.ovpn` → edit `remote 172.31.54.28 443 tcp-client` → connect via eduVPN → `ping 192.168.5.1` verify.

### Stage 7 — Harden & document
- Pin image versions
- Add restart / update workflow
- CI/CD for validation
- Migration plan for coworker's setups

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| `ra-validate: command not found` | Symlink missing | `sudo ln -sf /opt/ra-openvpn/ra-validate.sh /usr/local/bin/ra-validate` |
| `Validation failed` about port range | Invalid value in `.env` | Fix `.env` and re-run `ra-validate` |
| `interface 'eno1' does not exist` | Different NIC name | `ip -o link show` — set `RA_LAN_INTERFACE` accordingly |
| Client connects but can't reach 192.168.5.1 | Missing masquerade / forwarding | `sudo iptables -t nat -L POSTROUTING -n \| grep 10.99.99` and `sysctl net.ipv4.ip_forward` |
| Client can't connect at all | NAT rule wrong or university blocks | `sudo tcpdump -i eno1 tcp port 1195` while connecting; test `nc -vz 172.31.54.28 443` from eduVPN |
| Docker Compose won't parse | Missing/typo variable | `ra-validate` will point to which one |
| Broken symlink warnings | Renamed file, stale symlink | `sudo rm /usr/local/bin/ra-*` and recreate |
| Web UI unreachable | UFW rule missing / wrong subnet | `sudo ufw status verbose \| grep 8045`; `sudo ra-firewall status` |

