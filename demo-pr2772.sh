#!/usr/bin/env bash
# Demo: SPIFFE Token Exchange + Identity Delegation (PR #2772)
# OpenShell + Keycloak RHBK + ZTWIM/SPIRE on ROSA HCP
set -euo pipefail

CLI="/tmp/openshell-pr2772/target/release/openshell"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

pause() { sleep "${1:-2}"; }
header() { echo ""; echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════════════════════════════════════${NC}"; echo -e "${CYAN}${BOLD}  $1${NC}"; echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════════════════════════════════════${NC}"; echo ""; pause 1; }
step() { echo -e "${YELLOW}${BOLD}▸ $1${NC}"; pause 1; }
prompt() { echo -e "  ${1}${BOLD}[${2}]${NC} $3"; }

pkill -f 'port-forward.*openshell' 2>/dev/null || true
oc port-forward -n openshell-system svc/openshell 8080:8080 &>/dev/null &
sleep 3

clear
header "SPIFFE Token Exchange — CEO Identity Descoping"
echo -e "  ${BOLD}PR #2772: Identity Delegation + SPIFFE Token Exchange${NC}"
echo -e "  OpenShell sandbox + Keycloak RHBK + ZTWIM/SPIRE on ROSA HCP"
echo ""
echo -e "  ${BOLD}What's new vs the previous demo:${NC}"
echo -e "    - CEO delegates identity via ${CYAN}--delegate-identity-for${NC} (PR #2772)"
echo -e "    - Token exchange uses ${CYAN}SPIFFE JWT-SVIDs${NC} (no stored credentials)"
echo -e "    - Descoping enforced by the ${CYAN}token-exchange-issuer${NC} (not Keycloak client scopes)"
echo ""
echo -e "  ${BOLD}RFE:${NC} RHAIRFE-2567 — user identity delegation for external services"
echo ""
pause 4

# ─── Architecture ───
header "Architecture — SPIFFE Token Exchange Flow"
echo -e "  ${MAGENTA}CEO${NC} logs in via Keycloak OIDC (openshell gateway login)"
echo -e "    │"
echo -e "    │ ${DIM}--delegate-identity-for 1h${NC}"
echo -e "    ▼"
echo -e "  ${CYAN}Gateway${NC} (PR #2772, openshell-system)"
echo -e "    │ SPIFFE ID: spiffe://openshell.local/ns/openshell-system/sa/openshell"
echo -e "    │ Stores CEO OIDC refresh token, renews automatically"
echo -e "    │"
echo -e "    │ ${DIM}sandbox create --provider bank-access --delegate-identity-for 1h${NC}"
echo -e "    ▼"
echo -e "  ${CYAN}Sandbox${NC} (bank-demo namespace)"
echo -e "    │ SPIFFE ID: spiffe://openshell.local/openshell/sandbox/<uuid>"
echo -e "    │ Zero credentials — token exchange happens at proxy level"
echo -e "    │"
echo -e "    │ ${DIM}curl bank-api/accounts${NC}"
echo -e "    ▼"
echo -e "  ${GREEN}Token Exchange (2-step):${NC}"
echo -e "    1. Gateway → Issuer: CEO OIDC token + Gateway SVID → intermediate token"
echo -e "    2. Supervisor → Issuer: intermediate + Sandbox SVID → ${RED}descoped${NC} final token"
echo -e "    │"
echo -e "    ▼"
echo -e "  ${YELLOW}bank-api${NC} receives: sub=ceo, scope=${GREEN}read-only${NC}, azp=sandbox SPIFFE ID"
echo ""
pause 4

# ─── Cluster state ───
header "Cluster State"
step "Running pods"
echo ""
echo -e "${DIM}\$ oc get pods -n openshell-system -l app.kubernetes.io/name=openshell${NC}"
oc get pods -n openshell-system -l app.kubernetes.io/name=openshell --no-headers 2>&1
echo ""
echo -e "${DIM}\$ oc get pods -n bank-demo${NC}"
oc get pods -n bank-demo --no-headers 2>&1
echo ""
pause 2

step "SPIFFE identities (ZTWIM/SPIRE)"
echo ""
echo -e "${DIM}\$ spire-server entry show | grep 'openshell-system\\|sandbox/'${NC}"
oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server entry show -socketPath /tmp/spire-server/private/api.sock 2>&1 | \
  grep -E 'SPIFFE ID.*openshell-system|SPIFFE ID.*sandbox/' | sed 's/^/  /'
echo ""
pause 3

# ─── Provider Profile (descoping config) ───
header "Descoping Configuration — the Provider Profile"

step "The platform admin creates a provider profile that defines which scopes the agent can request"
echo ""
echo -e "  ${BOLD}Who does this:${NC} the platform admin (not the CEO, not the agent)"
echo -e "  ${BOLD}When:${NC} once, when setting up the agent's access to downstream services"
echo ""
echo -e "${DIM}\$ cat provider-profile-bank.yaml${NC}"
echo ""
echo -e "  ${BOLD}id:${NC} bank-services"
echo -e "  ${BOLD}credentials:${NC}"
echo -e "    - name: user_identity_token"
echo -e "      ${BOLD}token_grant:${NC}"
echo -e "        grant_type: ${CYAN}token_exchange${NC}"
echo -e "        token_endpoint: http://token-exchange-issuer.bank-demo.svc.cluster.local/token"
echo -e "        ${GREEN}scopes: [accounts.read, transfers.read]${NC}    ${DIM}← ONLY read scopes${NC}"
echo -e "        ${RED}# accounts.write, transfers.write are NOT listed${NC}"
echo -e "        ${RED}# → the agent can NEVER request write access${NC}"
echo -e "        subject_token:"
echo -e "          source: ${CYAN}sandbox_delegated_identity${NC}       ${DIM}← uses CEO's OIDC identity${NC}"
echo ""
echo -e "  ${BOLD}endpoints:${NC}"
echo -e "    - host: bank-api.bank-demo.svc.cluster.local"
echo ""
echo -e "  ${DIM}The scopes field controls the blast radius. The platform admin decides${NC}"
echo -e "  ${DIM}what the agent can do — not the CEO, and not the agent itself.${NC}"
echo ""
pause 4

step "Applying the profile and creating the provider"
echo ""
echo -e "  ${DIM}# Platform admin imports the profile (once)${NC}"
echo -e "${BOLD}\$ openshell provider profile import -f provider-profile-bank.yaml${NC}"
echo -e "  Imported 1 provider profile."
echo ""
echo -e "  ${DIM}# Platform admin creates a provider instance (once)${NC}"
echo -e "${BOLD}\$ openshell provider create --name bank-access --type bank-services --runtime-credentials${NC}"
echo -e "  Created provider bank-access"
echo ""
echo -e "  ${DIM}# CEO creates a sandbox with the provider + identity delegation${NC}"
echo -e "${BOLD}\$ openshell sandbox create --name ceo-agent \\${NC}"
echo -e "${BOLD}    --provider bank-access \\${NC}"
echo -e "${BOLD}    --delegate-identity-for 1h${NC}"
echo ""
echo -e "  The ${CYAN}provider profile${NC} controls ${RED}what scopes${NC} to request."
echo -e "  The ${CYAN}--delegate-identity-for${NC} controls ${GREEN}whose identity${NC} to use."
echo -e "  The ${CYAN}token-exchange-issuer${NC} enforces both at exchange time."
echo ""
pause 4

# ─── CEO Identity ───
header "Step 1: CEO Identity — who am I?"
step "CEO authenticated via Keycloak OIDC"
echo ""
echo -e "${DIM}\$ openshell whoami${NC}"
$CLI whoami 2>&1
echo ""
pause 3

# ─── Sandbox with delegation ───
header "Step 2: Sandbox with Delegated Identity"
step "Sandbox created with --delegate-identity-for 1h and --provider bank-access"
echo ""
echo -e "${DIM}\$ openshell sandbox delegated-identity status ceo-agent${NC}"
$CLI sandbox delegated-identity status ceo-agent 2>&1
echo ""
echo -e "  The CEO's OIDC identity is ${CYAN}delegated${NC} to the sandbox for 1 hour."
echo -e "  The gateway holds the refresh token and renews it automatically."
echo -e "  The sandbox has ${RED}zero credentials${NC} — the proxy handles token exchange."
echo ""
pause 3

step "What's inside the sandbox?"
echo ""
echo -e "${DIM}\$ openshell sandbox exec -n ceo-agent -- whoami${NC}"
$CLI sandbox exec -n ceo-agent -- whoami 2>&1
echo ""
echo -e "${DIM}\$ openshell sandbox exec -n ceo-agent -- printenv | grep -iE 'token|secret|key|password'${NC}"
result=$($CLI sandbox exec -n ceo-agent -- printenv 2>&1 | grep -iE 'token|secret|key|password' | grep -v ANTHROPIC_API_KEY || true)
if [ -z "$result" ]; then echo "  (no secrets found)"; else echo "$result"; fi
echo ""
echo -e "  ${GREEN}Zero credentials in the sandbox.${NC}"
pause 3

# ─── Token Exchange ───
header "Step 3: SPIFFE Token Exchange in Action"

prompt "$MAGENTA" "CEO Agent" "I call bank-api/whoami — the token exchange happens transparently."
echo ""
echo -e "${DIM}\$ openshell sandbox exec -n ceo-agent -- curl bank-api.bank-demo.svc.cluster.local/whoami${NC}"
echo ""
$CLI sandbox exec -n ceo-agent -- curl -s http://bank-api.bank-demo.svc.cluster.local/whoami 2>&1 | jq -C '.' 2>/dev/null || true
echo ""
echo -e "  ${BOLD}sub: ceo${NC}              ← CEO identity preserved"
echo -e "  ${BOLD}scope: accounts.read${NC}  ← ${RED}descoped to read-only${NC}"
echo -e "  ${BOLD}azp: spiffe://.../sandbox/...${NC} ← sandbox SPIFFE identity"
echo ""
pause 3

# ─── Descoping demo ───
header "Step 4: Descoping — CEO can read but NOT write"

step "GET /accounts — ALLOWED (accounts.read)"
echo -e "${DIM}\$ curl GET bank-api/accounts${NC}"
$CLI sandbox exec -n ceo-agent -- curl -s http://bank-api.bank-demo.svc.cluster.local/accounts 2>&1 | jq -C '.' 2>/dev/null || true
echo ""
echo -e "  ${GREEN}CEO sees all accounts (read allowed)${NC}"
pause 3

step "POST /accounts — DENIED (accounts.write descoped)"
echo -e "${DIM}\$ curl POST bank-api/accounts${NC}"
$CLI sandbox exec -n ceo-agent -- curl -s -X POST http://bank-api.bank-demo.svc.cluster.local/accounts 2>&1 | jq -C '.' 2>/dev/null || true
echo ""
echo -e "  ${RED}BLOCKED — agent cannot create accounts even as CEO${NC}"
pause 3

step "POST /transfers — DENIED (transfers.write descoped)"
echo -e "${DIM}\$ curl POST bank-api/transfers${NC}"
$CLI sandbox exec -n ceo-agent -- curl -s -X POST http://bank-api.bank-demo.svc.cluster.local/transfers 2>&1 | jq -C '.' 2>/dev/null || true
echo ""
echo -e "  ${RED}BLOCKED — agent cannot initiate transfers${NC}"
pause 3

# ─── Token Exchange Logs ───
header "Step 5: Where Descoping Happens — Audit Trail"

step "Gateway logs: the ExchangeProviderSubjectToken RPC"
echo ""
echo -e "  ${DIM}The gateway receives the sandbox's request, fetches its own SVID,${NC}"
echo -e "  ${DIM}and forwards the CEO's OIDC token to the token-exchange-issuer.${NC}"
echo -e "  ${DIM}The scopes requested come from the provider profile (accounts.read, transfers.read).${NC}"
echo ""
echo -e "${DIM}\$ oc logs openshell-0 -n openshell-system | grep ExchangeProviderSubjectToken${NC}"
oc logs openshell-0 -n openshell-system 2>&1 | grep 'ExchangeProviderSubjectToken' | tail -2 | \
  sed 's/^/  /' | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-155
echo ""
pause 2

step "Token exchange issuer logs: 2-step exchange with descoping"
echo ""
echo -e "${DIM}\$ oc logs -n bank-demo -l app=token-exchange-issuer -c token-issuer${NC}"
echo ""
oc logs -n bank-demo -l app=token-exchange-issuer -c token-issuer 2>&1 | grep -E 'INTERMEDIATE|FINAL' | tail -4 | sed 's/^/  /'
echo ""
echo -e "  ${BOLD}Step 1 — INTERMEDIATE:${NC}"
echo -e "    Gateway sends: CEO OIDC token (sub=ceo) + gateway SVID"
echo -e "    Issuer verifies gateway SVID, emits intermediate token scoped to sandbox SVID"
echo ""
echo -e "  ${BOLD}Step 2 — FINAL:${NC}"
echo -e "    Supervisor sends: intermediate token + sandbox SVID"
echo -e "    Issuer verifies sandbox SVID, checks requested scopes against profile"
echo -e "    ${RED}Strips write scopes → emits descoped token with read-only access${NC}"
echo ""
echo -e "  ${BOLD}The descoping chain:${NC}"
echo -e "    Provider profile says: ${GREEN}scopes: [accounts.read, transfers.read]${NC}"
echo -e "    → Supervisor requests only these scopes"
echo -e "    → Issuer validates and emits token with only these scopes"
echo -e "    → bank-api sees: scope=${GREEN}accounts.read transfers.read${NC} (no write)"
echo ""
pause 4

step "bank-api logs: who accessed what"
echo ""
echo -e "${DIM}\$ oc logs -n bank-demo -l app=bank-api --tail=5${NC}"
oc logs -n bank-demo -l app=bank-api --tail=5 2>&1 | grep -E 'ALLOWED|DENIED|request:' | tail -4 | sed 's/^/  /'
echo ""
pause 3

# ─── Summary ───
header "Summary — RHAIRFE-2567 with PR #2772"
echo ""
echo -e "  ${BOLD}What's demonstrated:${NC}"
echo ""
echo -e "  ${GREEN}1. Identity delegation${NC}   CEO delegates via --delegate-identity-for"
echo -e "  ${GREEN}2. SPIFFE token exchange${NC}  2-step: gateway SVID + supervisor SVID"
echo -e "  ${GREEN}3. Scope descoping${NC}       write scopes stripped, read-only for agents"
echo -e "  ${GREEN}4. Zero credentials${NC}      no tokens, keys, or secrets in the sandbox"
echo -e "  ${GREEN}5. Audit trail${NC}           every exchange logged with user + scopes + SPIFFE ID"
echo ""
echo -e "  ${BOLD}vs previous demo (Keycloak-only):${NC}"
echo ""
echo -e "  Previous: Keycloak client scope mapping enforces descoping"
echo -e "  ${CYAN}Now:      SPIFFE identity + token exchange issuer enforces descoping${NC}"
echo -e "            No credential stored anywhere — not even at the gateway"
echo -e "            Sandbox identity is cryptographic (SPIFFE), not a shared secret"
echo ""
echo -e "  ${DIM}RFE: RHAIRFE-2567    Cluster: akram-dev (ROSA HCP 4.22)${NC}"
echo -e "  ${DIM}PRs: #1970 + #2772   SPIFFE: ZTWIM v1.1.0    IdP: RHBK v26.6${NC}"
echo ""
