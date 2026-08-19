const http = require("http");
const crypto = require("crypto");

const PORT = Number(process.env.PORT || 8080);
const ACCESS_TOKEN_SECRET = process.env.ACCESS_TOKEN_SECRET;
const TOKEN_ISSUER = process.env.TOKEN_ISSUER;

const ACCOUNTS = {
  "ceo": [
    { id: "ACC-001", owner: "ceo@bank.com", balance: 5000000, type: "executive" },
    { id: "ACC-002", owner: "analyst@bank.com", balance: 85000, type: "standard" },
    { id: "ACC-003", owner: "intern@bank.com", balance: 32000, type: "standard" },
  ],
  "analyst": [
    { id: "ACC-002", owner: "analyst@bank.com", balance: 85000, type: "standard" },
  ],
};

function b64urlDecode(v) { return Buffer.from(v.replace(/-/g,"+").replace(/_/g,"/")+"=".repeat((4-v.length%4)%4),"base64"); }
function b64urlEncode(v) { return Buffer.from(v).toString("base64").replace(/=/g,"").replace(/\+/g,"-").replace(/\//g,"_"); }

function verifyToken(jwt) {
  const parts = jwt.split(".");
  if (parts.length !== 3) throw new Error("invalid JWT");
  const payload = JSON.parse(b64urlDecode(parts[1]).toString());

  if (ACCESS_TOKEN_SECRET) {
    const expected = b64urlEncode(crypto.createHmac("sha256", ACCESS_TOKEN_SECRET).update(parts[0]+"."+parts[1]).digest());
    if (parts[2] === expected) {
      if (payload.exp && payload.exp <= Date.now()/1000) throw new Error("token expired");
      return payload;
    }
  }
  throw new Error("token verification failed");
}

function hasScope(claims, scope) { return (claims.scope||"").split(/\s+/).includes(scope); }
function json(res,s,b) { const p=JSON.stringify(b,null,2); res.writeHead(s,{"content-type":"application/json"}); res.end(p); }

http.createServer((req, res) => {
  try {
    if (req.url === "/healthz") { res.writeHead(200); return res.end("ok\n"); }

    const auth = req.headers.authorization || "";
    const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
    if (!token) return json(res, 401, { error: "missing bearer token" });

    const claims = verifyToken(token);
    const user = claims.sub || "unknown";
    const email = claims.email || user+"@bank.com";
    const scope = claims.scope || "";
    const method = req.method;
    const path = req.url;

    console.log("request: user="+user+" email="+email+" method="+method+" path="+path+" scope=\""+scope+"\" azp="+claims.azp);

    if (path === "/accounts" && method === "GET") {
      if (!hasScope(claims,"accounts.read")) return json(res,403,{error:"missing scope: accounts.read",user,scope});
      const data = ACCOUNTS[user] || ACCOUNTS["analyst"] || [];
      console.log("ALLOWED: "+user+" read "+data.length+" accounts");
      return json(res,200,{user,email,scope,azp:claims.azp,accounts:data});
    }
    if (path === "/accounts" && method === "POST") {
      if (!hasScope(claims,"accounts.write")) return json(res,403,{error:"missing scope: accounts.write — agent is descoped to read-only",user,scope});
      return json(res,200,{user,message:"account created",scope});
    }
    if (path === "/transfers" && method === "GET") {
      if (!hasScope(claims,"transfers.read")) return json(res,403,{error:"missing scope: transfers.read",user,scope});
      return json(res,200,{user,email,scope,transfers:[{id:"TRF-001",from:"ACC-001",to:"EXT",amount:250000}]});
    }
    if (path === "/transfers" && method === "POST") {
      if (!hasScope(claims,"transfers.write")) return json(res,403,{error:"missing scope: transfers.write — agent cannot initiate transfers",user,scope});
      return json(res,200,{user,message:"transfer initiated",scope});
    }
    if (path === "/whoami") {
      return json(res,200,{sub:claims.sub,preferred_username:user,email,scope,azp:claims.azp,iss:claims.iss,token_use:claims.token_use});
    }
    return json(res,404,{error:"not found"});
  } catch(e) { console.error("error: "+e.message); return json(res,403,{error:e.message}); }
}).listen(PORT,"0.0.0.0",()=>console.log("bank-api listening on "+PORT));
