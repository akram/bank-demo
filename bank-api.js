const http = require("http");
const https = require("https");
const crypto = require("crypto");

const PORT = Number(process.env.PORT || 8080);
const KEYCLOAK_JWKS_URI = process.env.KEYCLOAK_JWKS_URI ||
  "https://keycloak-keycloak.apps.rosa.akram-dev.b5xj.p3.openshiftapps.com/realms/bank-demo/protocol/openid-connect/certs";
const KEYCLOAK_ISSUER = process.env.KEYCLOAK_ISSUER ||
  "https://keycloak-keycloak.apps.rosa.akram-dev.b5xj.p3.openshiftapps.com/realms/bank-demo";

// Simulated bank data
const ACCOUNTS = {
  "ceo@bank.com": [
    { id: "ACC-001", owner: "ceo@bank.com", balance: 5000000, type: "executive" },
    { id: "ACC-002", owner: "analyst@bank.com", balance: 85000, type: "standard" },
    { id: "ACC-003", owner: "intern@bank.com", balance: 32000, type: "standard" },
  ],
  "analyst@bank.com": [
    { id: "ACC-002", owner: "analyst@bank.com", balance: 85000, type: "standard" },
  ],
};

const TRANSFERS = {
  "ceo@bank.com": [
    { id: "TRF-001", from: "ACC-001", to: "ACC-002", amount: 10000, status: "completed" },
    { id: "TRF-002", from: "ACC-001", to: "EXT-VENDOR", amount: 250000, status: "pending" },
  ],
  "analyst@bank.com": [
    { id: "TRF-003", from: "ACC-002", to: "ACC-001", amount: 500, status: "completed" },
  ],
};

let cachedJwks;
let cachedJwksAt = 0;

function b64urlDecode(value) {
  const padded = `${value}${"=".repeat((4 - (value.length % 4)) % 4)}`;
  return Buffer.from(padded.replace(/-/g, "+").replace(/_/g, "/"), "base64");
}

function parseJwt(jwt) {
  const parts = jwt.split(".");
  if (parts.length !== 3) throw new Error("invalid JWT");
  return {
    header: JSON.parse(b64urlDecode(parts[0]).toString("utf8")),
    payload: JSON.parse(b64urlDecode(parts[1]).toString("utf8")),
    signingInput: `${parts[0]}.${parts[1]}`,
    signature: b64urlDecode(parts[2]),
  };
}

async function jwks() {
  const now = Date.now();
  if (cachedJwks && now - cachedJwksAt < 60000) return cachedJwks;
  cachedJwks = await fetchJson(KEYCLOAK_JWKS_URI);
  cachedJwksAt = now;
  return cachedJwks;
}

function fetchJson(url) {
  return new Promise((resolve, reject) => {
    const parsed = new URL(url);
    const client = parsed.protocol === "https:" ? https : http;
    const options = { rejectUnauthorized: false };
    const req = client.get(parsed, options, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () => {
        try { resolve(JSON.parse(Buffer.concat(chunks).toString("utf8"))); }
        catch (e) { reject(e); }
      });
    });
    req.on("error", reject);
    req.setTimeout(10000, () => req.destroy(new Error("timeout")));
  });
}

async function verifyToken(jwt) {
  const parsed = parseJwt(jwt);
  const keys = await jwks();
  const jwk = keys.keys.find((k) => k.kid === parsed.header.kid);
  if (!jwk) throw new Error(`no key for kid ${parsed.header.kid}`);

  const verifier = crypto.createVerify("RSA-SHA256");
  verifier.update(parsed.signingInput);
  verifier.end();
  const publicKey = crypto.createPublicKey({ key: jwk, format: "jwk" });
  if (!verifier.verify(publicKey, parsed.signature)) throw new Error("signature invalid");

  const now = Math.floor(Date.now() / 1000);
  if (parsed.payload.exp && parsed.payload.exp <= now) throw new Error("token expired");
  return parsed.payload;
}

function hasScope(claims, scope) {
  return (claims.scope || "").split(/\s+/).includes(scope);
}

function text(res, status, body) {
  res.writeHead(status, { "content-type": "text/plain" });
  res.end(body);
}

function json(res, status, body) {
  const payload = JSON.stringify(body, null, 2);
  res.writeHead(status, { "content-type": "application/json" });
  res.end(payload);
}

http.createServer(async (req, res) => {
  try {
    if (req.url === "/healthz") return text(res, 200, "ok\n");

    const auth = req.headers.authorization || "";
    const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
    if (!token) {
      console.warn(`rejected: missing bearer token path=${req.url}`);
      return json(res, 401, { error: "missing bearer token" });
    }

    const claims = await verifyToken(token);
    const user = claims.preferred_username || claims.sub;
    const email = claims.email || `${user}@bank.com`;
    const scope = claims.scope || "";
    const method = req.method;
    const path = req.url;

    console.log(`request: user=${user} email=${email} method=${method} path=${path} scope="${scope}" azp=${claims.azp}`);

    // GET /accounts — requires accounts.read
    if (path === "/accounts" && method === "GET") {
      if (!hasScope(claims, "accounts.read")) {
        console.warn(`DENIED: ${user} lacks accounts.read`);
        return json(res, 403, { error: "missing scope: accounts.read", user, scope });
      }
      const data = ACCOUNTS[email] || [];
      console.log(`ALLOWED: ${user} read ${data.length} accounts`);
      return json(res, 200, { user, email, scope, accounts: data });
    }

    // POST /accounts — requires accounts.write (DESCOPED for agents)
    if (path === "/accounts" && method === "POST") {
      if (!hasScope(claims, "accounts.write")) {
        console.warn(`DENIED: ${user} lacks accounts.write (DESCOPED)`);
        return json(res, 403, { error: "missing scope: accounts.write — agent is descoped to read-only", user, scope });
      }
      return json(res, 200, { user, message: "account created", scope });
    }

    // GET /transfers — requires transfers.read
    if (path === "/transfers" && method === "GET") {
      if (!hasScope(claims, "transfers.read")) {
        console.warn(`DENIED: ${user} lacks transfers.read`);
        return json(res, 403, { error: "missing scope: transfers.read", user, scope });
      }
      const data = TRANSFERS[email] || [];
      console.log(`ALLOWED: ${user} read ${data.length} transfers`);
      return json(res, 200, { user, email, scope, transfers: data });
    }

    // POST /transfers — requires transfers.write (DESCOPED for agents)
    if (path === "/transfers" && method === "POST") {
      if (!hasScope(claims, "transfers.write")) {
        console.warn(`DENIED: ${user} lacks transfers.write (DESCOPED)`);
        return json(res, 403, { error: "missing scope: transfers.write — agent cannot initiate transfers", user, scope });
      }
      return json(res, 200, { user, message: "transfer initiated", scope });
    }

    // Identity info endpoint
    if (path === "/whoami") {
      return json(res, 200, {
        sub: claims.sub,
        preferred_username: user,
        email,
        scope,
        azp: claims.azp,
        iss: claims.iss,
      });
    }

    return json(res, 404, { error: "not found" });
  } catch (error) {
    console.error(`error: ${error.message}`);
    return json(res, 403, { error: error.message });
  }
}).listen(PORT, "0.0.0.0", () => {
  console.log(`bank-api listening on ${PORT}`);
});
