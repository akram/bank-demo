# Bank Demo — CEO Identity Descoping for AI Agents

Demonstrates user identity delegation with scope descoping using OpenShell sandboxes and Keycloak RFC 8693 token exchange.

## Scenario

A bank CEO logs in. An AI agent acts on their behalf inside an OpenShell sandbox. The agent can **read** bank data but **cannot write** — even though the CEO has full permissions. The downstream banking API sees the CEO's identity (`sub=ceo`, `email=ceo@bank.com`) but with reduced scopes (`accounts.read` only, no `accounts.write`).

This validates [RHAIRFE-2567](https://redhat.atlassian.net/browse/RHAIRFE-2567): OpenShell user identity delegation via token exchange.

## Architecture

```
CEO (Keycloak OIDC login)
  → OpenShell Gateway (token exchange, RFC 8693)
    → Sandbox Pod (network-isolated, zero credentials)
      → bank-api (validates token, enforces scopes)
```

## Components

| File | Purpose |
|------|---------|
| `bank-api.js` | Simulated banking API with scope-based access control |
| `workloads.yaml` | Kubernetes manifests for bank-api deployment |
| `provider-profile-bank.yaml` | OpenShell provider profile with token exchange config |
| `ceo-agent-policy.yaml` | Sandbox network policy allowing bank-api access |
| `demo-descoping.sh` | Asciinema demo script |
| `demo-descoping.cast` | Recorded asciinema demo |
| `build/Dockerfile.gateway.openshift` | Multi-stage Dockerfile for gateway (Rust + Z3 EPEL) |
| `build/Dockerfile.supervisor.openshift` | Multi-stage Dockerfile for supervisor |

## Demo

[![Demo with AI voice over](https://asciinema.org/a/kQYuXjvXScHoW4zE.svg)](https://akram.github.io/bank-demo/demo-player.html)

*Click the image above to open the interactive demo with synchronized AI voice over narration (play, pause, seek all work).*

```bash
# Play locally
asciinema play demo-descoping.cast

# Re-record
asciinema rec demo-descoping.cast --command "bash demo-descoping.sh" --cols 160 --rows 50
```

## Prerequisites

- ROSA HCP cluster with OpenShell v0.0.98+
- Red Hat Build of Keycloak (RHBK operator)
- ZTWIM/SPIRE for SPIFFE identity (for PR #1970/#2772 token exchange)

## Keycloak Setup

Realm `bank-demo` with:
- Users: `ceo@bank.com` (admin), `analyst@bank.com` (user)
- Client `openshell-gateway`: full scopes, token exchange enabled
- Client `agent-sandbox`: read-only scopes (accounts.read, transfers.read)
- Features: `token-exchange`, `admin-fine-grained-authz`

## Related

- [RHAIRFE-2567](https://redhat.atlassian.net/browse/RHAIRFE-2567) — RFE
- [OpenShell PR #1970](https://github.com/NVIDIA/OpenShell/pull/1970) — SPIFFE token exchange
- [OpenShell PR #2772](https://github.com/NVIDIA/OpenShell/pull/2772) — Identity delegation
