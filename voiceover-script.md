# Voice Over Script — CEO Identity Descoping Demo

**Duration:** ~2 minutes (matches the 101s asciinema recording)
**Tone:** Technical but accessible. You're showing this to engineering peers and product stakeholders.

---

## [0:00 — Title screen]

This demo shows how OpenShell can delegate a user's identity to an AI agent while reducing the agent's permissions — what we call identity descoping.

We're addressing RFE twenty-five sixty-seven: user identity delegation for external services.

## [0:10 — Architecture diagram]

Here's the setup. A bank CEO authenticates via Keycloak OIDC. When they create a sandbox, they delegate their identity using the new `delegate-identity-for` flag from PR twenty-seven seventy-two.

The key is the two-step SPIFFE token exchange. First, the gateway exchanges the CEO's OIDC token with its own SPIFFE identity. Then, the sandbox supervisor exchanges the intermediate token with its own SPIFFE identity. The result is a final token that preserves the CEO's identity but with reduced scopes.

Everything runs on ROSA HCP with the Zero Trust Workload Identity Manager for SPIRE.

## [0:35 — Provider Profile]

This is where descoping is configured — the provider profile. The platform admin writes this, not the CEO, and not the agent.

The critical field is `scopes`. It lists only `accounts.read` and `transfers.read`. Write scopes are simply not listed. The agent can never request them. This is the blast radius control.

The `source: sandbox_delegated_identity` means the token exchange will use whichever user created the sandbox — in this case, the CEO.

## [0:55 — CEO Identity + Delegation]

The CEO is authenticated via Keycloak. `openshell who am I` shows the subject, the name, and the OIDC provider.

The sandbox has a delegated identity — active, with fifty-seven minutes remaining. Inside the sandbox, there are zero credentials. No tokens, no keys, no secrets. The proxy handles everything transparently.

## [1:10 — Token Exchange in Action]

When the agent calls `bank-api/who am I`, the token exchange happens at the proxy level. The response shows `sub: ceo` — the CEO's identity is preserved. But the scope is `accounts.read transfers.read` only. No write access.

The `azp` field shows the sandbox's SPIFFE identity — that's the cryptographic proof of which sandbox made the request.

## [1:25 — Descoping Results]

GET accounts — two hundred. The CEO sees all three accounts. Read access works.

POST accounts — four-oh-three. "Agent is descoped to read-only." The CEO has write access, but the agent doesn't.

POST transfers — four-oh-three. "Agent cannot initiate transfers." Same identity, reduced permissions.

## [1:40 — Audit Trail]

The logs show the full chain. The gateway logs the `ExchangeProviderSubjectToken` RPC. The token exchange issuer logs both steps — intermediate and final — with the user, the scopes, and the SPIFFE client ID. The bank-api logs every request with ALLOWED or DENIED.

## [1:50 — Summary]

Five things demonstrated. Identity delegation with `delegate-identity-for`. SPIFFE token exchange — two-step, with cryptographic identities. Scope descoping controlled by the platform admin's provider profile. Zero credentials in the sandbox. And a complete audit trail.

The key difference from the previous Keycloak-only demo: descoping is now enforced by SPIFFE identity and the token exchange issuer, not by Keycloak client scope mappings. No credential is stored anywhere — not even at the gateway. The sandbox identity is cryptographic, not a shared secret.

---

**End.**
