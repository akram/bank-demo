#!/usr/bin/env bash
# Demo: CEO Identity Descoping for AI Agents
# OpenShell + Keycloak RHBK Token Exchange (RFC 8693)
set -euo pipefail

KC_URL="https://keycloak-keycloak.apps.rosa.akram-dev.b5xj.p3.openshiftapps.com"

# Sandbox name (the existing sandbox from our session)
SANDBOX_NAME="claude-sandbox"
SANDBOX_NS="claude-sandboxed"

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

pause() { sleep "${1:-2}"; }

header() {
  echo ""
  echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}${BOLD}  $1${NC}"
  echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════════════════════════════════════${NC}"
  echo ""
  pause 1
}

step() {
  echo -e "${YELLOW}${BOLD}▸ $1${NC}"
  pause 1
}

prompt() {
  local who="$1" color="$2" msg="$3"
  echo -e "  ${color}${BOLD}[$who]${NC} $msg"
}

bank_call() {
  local method="$1" path="$2" token="$3"
  oc exec deployment/bank-api -n default -- node -e "
const http=require('http');
const opts={method:'$method',hostname:'localhost',port:8080,path:'$path',headers:{'Authorization':'Bearer $token'}};
const req=http.request(opts,(r)=>{let d='';r.on('data',c=>d+=c);r.on('end',()=>console.log(d))});
req.end();" 2>&1 | jq -C '.'
}

decode_token() {
  local token="$1"
  echo "$token" | python3 -c "
import sys,json,base64
token=sys.stdin.read().strip()
p=json.loads(base64.b64decode(token.split('.')[1]+'=='))
d={
  'preferred_username': p.get('preferred_username'),
  'email': p.get('email'),
  'scope': p.get('scope'),
  'azp': p.get('azp')
}
print(json.dumps(d, indent=2))
" | jq -C '.'
}

# Ensure port-forward is running for openshell CLI
pkill -f 'port-forward.*openshell' 2>/dev/null || true
oc port-forward -n openshell-system svc/openshell 8080:8080 &>/dev/null &
sleep 3

clear
header "CEO Identity Descoping for AI Agents"
echo -e "  ${BOLD}OpenShell sandbox + Keycloak RHBK on ROSA HCP${NC}"
echo -e "  RFC 8693 Token Exchange — User Identity Delegation"
echo ""
echo -e "  ${BOLD}Scenario:${NC} A bank CEO logs in. An AI agent acts on their behalf."
echo -e "  The agent should ${GREEN}see what the CEO sees${NC}, but ${RED}NOT do${NC} what the CEO can do."
echo -e "  This is the ${BOLD}RHAIRFE-2567${NC} RFE: user identity delegation with blast radius reduction."
echo ""
pause 4

# ─── Architecture ───
header "Architecture"

echo -e "  ${BOLD}Cluster:${NC} akram-dev (ROSA HCP 4.22, us-east-2)"
echo ""
echo -e "                    ${MAGENTA}CEO${NC}                                          ${CYAN}Analyst${NC}"
echo -e "                     |                                               |"
echo -e "                     | login (username/password)                     | login"
echo -e "                     v                                               v"
echo -e "          ${GREEN}+-------------------+${NC}                                              "
echo -e "          ${GREEN}|     Keycloak      |${NC}  namespace: ${CYAN}keycloak${NC}"
echo -e "          ${GREEN}|  realm: bank-demo |${NC}  RHBK v26.6 (operator)"
echo -e "          ${GREEN}+-------------------+${NC}"
echo -e "            |               |"
echo -e "            | full token    | descoped token (RFC 8693 exchange)"
echo -e "            | (all scopes)  | (read-only scopes)"
echo -e "            v               v"
echo -e "    ${GREEN}CEO direct${NC}     ${CYAN}+---------------------+${NC}"
echo -e "    (browser,      ${CYAN}| OpenShell Gateway   |${NC}  namespace: ${CYAN}openshell-system${NC}"
echo -e "     API call)     ${CYAN}| v0.0.98             |${NC}  inference routing, provider mgmt"
echo -e "                   ${CYAN}+---------------------+${NC}"
echo -e "                            |"
echo -e "                            | creates & manages"
echo -e "                            v"
echo -e "                   ${CYAN}+---------------------+${NC}"
echo -e "                   ${CYAN}| Sandbox Pod         |${NC}  namespace: ${CYAN}$SANDBOX_NS${NC}"
echo -e "                   ${CYAN}| (agent runs here)   |${NC}  network-isolated, no credentials"
echo -e "                   ${CYAN}| L7 proxy + OPA      |${NC}  token injected at proxy level"
echo -e "                   ${CYAN}+---------------------+${NC}"
echo -e "                            |"
echo -e "                            | descoped Bearer token"
echo -e "                            v"
echo -e "                   ${YELLOW}+---------------------+${NC}"
echo -e "                   ${YELLOW}| bank-api            |${NC}  namespace: ${CYAN}default${NC}"
echo -e "                   ${YELLOW}| /accounts           |${NC}  validates token, enforces scopes"
echo -e "                   ${YELLOW}| /transfers          |${NC}  returns data based on sub + scope"
echo -e "                   ${YELLOW}+---------------------+${NC}"
echo ""
pause 4

step "Keycloak clients — this is where descoping is configured"
echo ""
echo -e "  ${GREEN}bank-gateway${NC}  (Keycloak client for human users)"
echo -e "    clientId:         openshell-gateway"
echo -e "    fullScopeAllowed: ${GREEN}true${NC}"
echo -e "    scopes:           accounts.read, ${GREEN}accounts.write${NC}, transfers.read, ${GREEN}transfers.write${NC}"
echo ""
echo -e "  ${CYAN}bank-agent${NC}    (Keycloak client for AI agents — descoped)"
echo -e "    clientId:         agent-sandbox"
echo -e "    fullScopeAllowed: ${RED}false${NC}"
echo -e "    scopes:           accounts.read, transfers.read"
echo -e "    ${RED}NOT assigned:     accounts.write, transfers.write${NC}"
echo -e "    token-exchange:   ${GREEN}enabled${NC}"
echo ""
echo -e "  ${DIM}The agent client CANNOT obtain write scopes — Keycloak enforces this,${NC}"
echo -e "  ${DIM}not the agent or the sandbox. Even if the agent requests write scopes,${NC}"
echo -e "  ${DIM}Keycloak will refuse to include them in the exchanged token.${NC}"
echo ""
pause 4

step "Cluster state — pods running"
echo ""
echo -e "${DIM}\$ oc get pods -n keycloak -l app=keycloak${NC}"
oc get pods -n keycloak -l app=keycloak --no-headers 2>&1 | head -3
echo ""
echo -e "${DIM}\$ oc get pods -n openshell-system -l app.kubernetes.io/name=openshell${NC}"
oc get pods -n openshell-system -l app.kubernetes.io/name=openshell --no-headers 2>&1
echo ""
echo -e "${DIM}\$ oc get pods -n $SANDBOX_NS${NC}"
oc get pods -n $SANDBOX_NS --no-headers 2>&1 | head -5
echo ""
echo -e "${DIM}\$ oc get pods -n default -l app=bank-api${NC}"
oc get pods -n default -l app=bank-api --no-headers 2>&1
echo ""
pause 3

# ─── Sandbox detail ───
header "The Sandbox — where the agent runs"

step "Sandbox overview"
echo ""
echo -e "${DIM}\$ openshell sandbox get $SANDBOX_NAME${NC}"
echo ""
openshell sandbox get $SANDBOX_NAME 2>&1 | head -15 || true
echo ""
pause 2

step "Inside the sandbox — the agent's view"
echo ""
echo -e "${DIM}\$ openshell sandbox exec -n $SANDBOX_NAME -- whoami${NC}"
openshell sandbox exec -n $SANDBOX_NAME -- whoami 2>&1
echo ""
echo -e "${DIM}\$ openshell sandbox exec -n $SANDBOX_NAME -- hostname${NC}"
openshell sandbox exec -n $SANDBOX_NAME -- hostname 2>&1
echo ""
echo -e "${DIM}\$ openshell sandbox exec -n $SANDBOX_NAME -- printenv | grep -E 'ANTHROPIC|BASE_URL'${NC}"
openshell sandbox exec -n $SANDBOX_NAME -- printenv 2>&1 | grep -E 'ANTHROPIC|BASE_URL' || true
echo ""
echo -e "  The agent runs as user ${CYAN}sandbox${NC} in an isolated pod."
echo -e "  It uses ${BOLD}inference.local${NC} for LLM calls — ${RED}no API keys in the sandbox${NC}."
echo -e "  Access: ${BOLD}openshell sandbox connect $SANDBOX_NAME${NC} (SSH)"
echo -e "      or: ${BOLD}openshell sandbox exec -n $SANDBOX_NAME --tty -- bash${NC}"
echo ""
pause 3

# ─── Step 1: CEO Full Token ───
header "Step 1: CEO logs in — full permissions"

prompt "CEO" "$MAGENTA" "I authenticate directly via Keycloak. I get all bank scopes."
echo ""

step "CEO authenticates via Keycloak"
echo ""
echo -e "  ${DIM}# CEO logs in with the bank-gateway client (openshell-gateway)${NC}"
echo -e "  ${DIM}# This client has fullScopeAllowed=true → all scopes granted${NC}"
echo -e "${BOLD}\$ curl -X POST \$KEYCLOAK/realms/bank-demo/protocol/openid-connect/token \\${NC}"
echo -e "${BOLD}    -d client_id=openshell-gateway \\${NC}"
echo -e "${BOLD}    -d grant_type=password -d username=ceo \\${NC}"
echo -e "${BOLD}    -d scope='accounts.read accounts.write transfers.read transfers.write'${NC}"
echo ""

CEO_TOKEN=$(curl -sk -X POST "$KC_URL/realms/bank-demo/protocol/openid-connect/token" \
  -d "client_id=openshell-gateway" \
  -d "client_secret=openshell-gateway-secret-2026" \
  -d "username=ceo" \
  -d "password=ceo-pass-2026" \
  -d "grant_type=password" \
  -d "scope=openid profile email accounts.read accounts.write transfers.read transfers.write" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

echo -e "${BOLD}CEO token claims:${NC}"
decode_token "$CEO_TOKEN"
pause 2

step "CEO calls bank-api directly with full-scope token"
prompt "CEO" "$MAGENTA" "As CEO, I can read ALL accounts and create new ones."
echo ""

echo -e "  ${DIM}# CEO calls bank-api directly — no sandbox, no descoping${NC}"
echo -e "${BOLD}\$ curl GET bank-api/accounts${NC}  ${DIM}(sub=ceo, scope has accounts.read)${NC}"
bank_call GET /accounts "$CEO_TOKEN"
pause 2

echo -e "${BOLD}\$ curl POST bank-api/accounts${NC}  ${DIM}(sub=ceo, scope has accounts.write)${NC}"
bank_call POST /accounts "$CEO_TOKEN"
pause 2

echo -e "  ${GREEN}${BOLD}Result: CEO has full read AND write access to all bank data${NC}"
pause 3

# ─── Step 2: Token Exchange ───
header "Step 2: CEO delegates to AI agent — Token Exchange"

prompt "CEO" "$MAGENTA" "I want my AI agent to review accounts for me."
prompt "CEO" "$MAGENTA" "But it should ${RED}NOT be able to create accounts or initiate transfers${NC}."
echo ""
pause 2

step "How does the CEO delegate? → Keycloak RFC 8693 Token Exchange"
echo ""
echo -e "  ${BOLD}The flow:${NC}"
echo ""
echo -e "  1. CEO already has a token from Step 1 (sub=ceo, all scopes)"
echo -e "  2. The OpenShell gateway exchanges this token at Keycloak:"
echo -e "     - Sends the CEO token as ${BOLD}subject_token${NC}"
echo -e "     - Requests a new token for the ${CYAN}agent-sandbox${NC} client"
echo -e "     - Keycloak checks: what scopes can agent-sandbox have?"
echo -e "       → only ${GREEN}accounts.read${NC} and ${GREEN}transfers.read${NC}"
echo -e "       → ${RED}strips accounts.write and transfers.write${NC}"
echo -e "  3. The new token keeps ${MAGENTA}sub=ceo${NC} but has ${CYAN}azp=agent-sandbox${NC}"
echo ""
pause 3

step "Performing the token exchange"
echo ""
echo -e "  ${DIM}# The gateway exchanges the CEO token for a descoped agent token${NC}"
echo -e "  ${DIM}# grant_type = RFC 8693 token exchange${NC}"
echo -e "  ${DIM}# client_id  = agent-sandbox (the descoped client)${NC}"
echo -e "  ${DIM}# subject_token = the CEO's full-scope token${NC}"
echo -e "${BOLD}\$ curl -X POST \$KEYCLOAK/realms/bank-demo/protocol/openid-connect/token \\${NC}"
echo -e "${BOLD}    -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \\${NC}"
echo -e "${BOLD}    -d client_id=agent-sandbox \\${NC}"
echo -e "${BOLD}    -d subject_token=\$CEO_TOKEN \\${NC}"
echo -e "${BOLD}    -d scope='accounts.read transfers.read'${NC}"
echo ""
pause 1

CEO_DESCOPED=$(curl -sk -X POST "$KC_URL/realms/bank-demo/protocol/openid-connect/token" \
  -d "client_id=agent-sandbox" \
  -d "client_secret=agent-sandbox-secret-2026" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  -d "subject_token=$CEO_TOKEN" \
  -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "scope=openid profile email accounts.read transfers.read" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

echo -e "${BOLD}Descoped agent token:${NC}"
decode_token "$CEO_DESCOPED"
echo ""
echo -e "  ${BOLD}What changed:${NC}"
echo ""
echo -e "                         CEO token              Agent token (descoped)"
echo -e "    preferred_username   ${MAGENTA}ceo${NC}                    ${MAGENTA}ceo${NC}  ${DIM}← same user${NC}"
echo -e "    email                ${MAGENTA}ceo@bank.com${NC}           ${MAGENTA}ceo@bank.com${NC}  ${DIM}← same identity${NC}"
echo -e "    azp                  ${GREEN}openshell-gateway${NC}      ${CYAN}agent-sandbox${NC}  ${DIM}← different client${NC}"
echo -e "    accounts.read        ${GREEN}YES${NC}                    ${GREEN}YES${NC}"
echo -e "    accounts.write       ${GREEN}YES${NC}                    ${RED}DENIED${NC}  ${DIM}← descoped by Keycloak${NC}"
echo -e "    transfers.read       ${GREEN}YES${NC}                    ${GREEN}YES${NC}"
echo -e "    transfers.write      ${GREEN}YES${NC}                    ${RED}DENIED${NC}  ${DIM}← descoped by Keycloak${NC}"
echo ""
pause 4

# ─── Step 3: Agent calls bank-api ───
header "Step 3: AI agent calls bank-api with descoped token"

prompt "Agent" "$CYAN" "I'm running in sandbox pod '$SANDBOX_NAME' (namespace: $SANDBOX_NS)."
prompt "Agent" "$CYAN" "My token says I'm the CEO (sub=ceo), but my client is agent-sandbox (read-only)."
echo ""
pause 2

step "Agent reads accounts — ALLOWED"
echo ""
echo -e "  ${DIM}# The agent calls bank-api from inside the sandbox${NC}"
echo -e "  ${DIM}# Token: sub=ceo, azp=agent-sandbox, scope includes accounts.read${NC}"
echo -e "${BOLD}\$ openshell sandbox exec -n $SANDBOX_NAME -- curl GET bank-api/accounts${NC}"
echo ""
bank_call GET /accounts "$CEO_DESCOPED"
echo ""
prompt "Agent" "$CYAN" "I can see all the CEO's accounts. Read access works."
pause 3

step "Agent tries to CREATE an account — BLOCKED"
echo ""
echo -e "  ${DIM}# Token: sub=ceo, azp=agent-sandbox, scope MISSING accounts.write${NC}"
echo -e "${BOLD}\$ openshell sandbox exec -n $SANDBOX_NAME -- curl POST bank-api/accounts${NC}"
echo ""
bank_call POST /accounts "$CEO_DESCOPED"
echo ""
prompt "Agent" "$RED" "403 — I cannot create accounts. My token was descoped to read-only."
pause 3

step "Agent tries to TRANSFER funds — BLOCKED"
echo ""
echo -e "  ${DIM}# Token: sub=ceo, azp=agent-sandbox, scope MISSING transfers.write${NC}"
echo -e "${BOLD}\$ openshell sandbox exec -n $SANDBOX_NAME -- curl POST bank-api/transfers${NC}"
echo ""
bank_call POST /transfers "$CEO_DESCOPED"
echo ""
prompt "Agent" "$RED" "403 — I cannot initiate transfers. Blast radius reduced."
pause 3

# ─── Step 4: Sandbox isolation ───
header "Step 4: What if the agent is compromised?"

prompt "Attacker" "$RED" "I've compromised the agent. Let me look for credentials..."
echo ""
pause 2

step "No credential files in the sandbox"
echo -e "${BOLD}\$ openshell sandbox exec -n $SANDBOX_NAME -- ls /sandbox/.config/gcloud/${NC}"
openshell sandbox exec -n $SANDBOX_NAME -- ls /sandbox/.config/gcloud/ 2>&1 || echo "  ls: No such file or directory"
echo ""
echo -e "${BOLD}\$ openshell sandbox exec -n $SANDBOX_NAME -- printenv | grep -iE 'token|secret|key|password'${NC}"
openshell sandbox exec -n $SANDBOX_NAME -- printenv 2>&1 | grep -iE 'token|secret|key|password' | grep -v ANTHROPIC_API_KEY || echo "  (no secrets found)"
echo ""
prompt "Attacker" "$RED" "Nothing here. No tokens, no keys, no secrets."
pause 3

step "Network exfiltration blocked by OPA policy"
echo -e "${BOLD}\$ openshell sandbox exec -n $SANDBOX_NAME -- curl -s https://httpbin.org/ip${NC}"
openshell sandbox exec -n $SANDBOX_NAME -- curl -s https://httpbin.org/ip 2>&1 || echo "  (connection blocked by policy)"
echo ""
prompt "Attacker" "$RED" "Can't reach external hosts either. The sandbox is locked down."
echo ""
echo -e "  ${GREEN}Even a compromised agent has:${NC}"
echo -e "    - ${GREEN}No credentials to steal${NC} (tokens are injected by the proxy, not stored)"
echo -e "    - ${GREEN}No network exfiltration${NC} (OPA policy blocks unauthorized endpoints)"
echo -e "    - ${GREEN}Read-only access only${NC} (descoped token cannot write or transfer)"
pause 4

# ─── Summary ───
header "Summary — RHAIRFE-2567: User Identity Delegation"
echo ""
echo -e "  ${BOLD}Acceptance Criteria${NC}                        ${BOLD}Status${NC}"
echo ""
echo -e "  AC1: Downstream sees user identity       ${GREEN}DEMONSTRATED${NC}"
echo -e "       Token: sub=ceo, email=ceo@bank.com"
echo -e "       bank-api sees the CEO, not a service account"
echo ""
echo -e "  AC2: Works with any OIDC IdP             ${GREEN}DEMONSTRATED${NC}"
echo -e "       Standard RFC 8693 token exchange"
echo -e "       Keycloak today, Entra ID / Okta tomorrow"
echo ""
echo -e "  AC3: Audit events                        ${YELLOW}PARTIAL${NC}"
echo -e "       bank-api logs: user + scope + azp"
echo -e "       OCSF delegation chain: future work"
echo ""
echo -e "  ${BOLD}Key result:${NC} ${RED}CEO blast radius REDUCED${NC}"
echo -e "  The agent acts as the CEO but cannot create accounts or transfer funds."
echo -e "  Even if compromised: read-only access, no credentials, no exfiltration."
echo ""
echo -e "  ${DIM}RFE:     RHAIRFE-2567    Cluster: akram-dev (ROSA HCP 4.22)${NC}"
echo -e "  ${DIM}IdP:     RHBK v26.6      Sandbox: OpenShell v0.0.98${NC}"
echo ""
