const http = require("http");
const https = require("https");
const crypto = require("crypto");

const TOKEN_EXCHANGE_GRANT_TYPE = "urn:ietf:params:oauth:grant-type:token-exchange";
const JWT_SPIFFE_ASSERTION_TYPE = "urn:ietf:params:oauth:client-assertion-type:jwt-spiffe";

const PORT = Number(process.env.PORT || 8080);
const JWKS_URI = process.env.SPIRE_JWKS_URI;
const SPIRE_ISSUER = process.env.SPIRE_ISSUER;
const JWT_SVID_AUDIENCE = process.env.JWT_SVID_AUDIENCE;
const SUPERVISOR_TRUST_DOMAIN_PREFIX = process.env.SUPERVISOR_TRUST_DOMAIN_PREFIX || "spiffe://openshell.local/openshell/sandbox/";
const GATEWAY_TRUST_DOMAIN_PREFIX = process.env.GATEWAY_TRUST_DOMAIN_PREFIX || "spiffe://openshell.local/ns/openshell-system/sa/";
const ACCESS_TOKEN_SECRET = process.env.ACCESS_TOKEN_SECRET;

if (!ACCESS_TOKEN_SECRET) throw new Error("ACCESS_TOKEN_SECRET required");

let cachedJwks, cachedJwksAt = 0;

function b64urlDecode(v) { return Buffer.from(v.replace(/-/g,"+").replace(/_/g,"/")+"=".repeat((4-v.length%4)%4),"base64"); }
function b64urlEncode(v) { return Buffer.from(v).toString("base64").replace(/=/g,"").replace(/\+/g,"-").replace(/\//g,"_"); }
function parseJwt(jwt) { const p=jwt.split("."); return{header:JSON.parse(b64urlDecode(p[0])),payload:JSON.parse(b64urlDecode(p[1])),signingInput:p[0]+"."+p[1],signature:b64urlDecode(p[2]),signatureB64:p[2]}; }

function fetchJson(url) {
  return new Promise((resolve,reject) => {
    const p=new URL(url); const c=p.protocol==="https:"?https:http;
    c.get(p,{rejectUnauthorized:false},r=>{const ch=[];r.on("data",d=>ch.push(d));r.on("end",()=>{try{resolve(JSON.parse(Buffer.concat(ch).toString()))}catch(e){reject(e)}})}).on("error",reject).setTimeout(10000,function(){this.destroy(new Error("timeout"))});
  });
}
async function jwks() { if(cachedJwks&&Date.now()-cachedJwksAt<60000)return cachedJwks; cachedJwks=await fetchJson(JWKS_URI); cachedJwksAt=Date.now(); return cachedJwks; }
function hasAudience(p,e) { return(Array.isArray(p.aud)?p.aud:[p.aud]).includes(e); }

async function verifyJwtSvid(jwt, subjectPrefix) {
  const parsed = parseJwt(jwt);
  const keys = await jwks();
  const jwk = keys.keys.find(k => k.kid === parsed.header.kid);
  if (!jwk) throw new Error("no key for kid "+parsed.header.kid);
  const v = crypto.createVerify("RSA-SHA256"); v.update(parsed.signingInput); v.end();
  if (!v.verify(crypto.createPublicKey({key:jwk,format:"jwk"}), parsed.signature)) throw new Error("sig invalid");
  if (parsed.payload.exp && parsed.payload.exp <= Date.now()/1000) throw new Error("expired");
  if (parsed.payload.iss !== SPIRE_ISSUER) throw new Error("bad issuer: "+parsed.payload.iss);
  if (!hasAudience(parsed.payload, JWT_SVID_AUDIENCE)) throw new Error("bad audience");
  if (!String(parsed.payload.sub||"").startsWith(subjectPrefix)) throw new Error("bad sub prefix: "+parsed.payload.sub+" expected: "+subjectPrefix);
  return parsed.payload;
}

function signToken(payload) {
  const h=b64urlEncode(JSON.stringify({alg:"HS256",typ:"JWT"}));
  const b=b64urlEncode(JSON.stringify(payload));
  const sig=crypto.createHmac("sha256",ACCESS_TOKEN_SECRET).update(h+"."+b).digest();
  return h+"."+b+"."+b64urlEncode(sig);
}

function verifyHmacToken(jwt) {
  const parsed = parseJwt(jwt);
  const expected = b64urlEncode(crypto.createHmac("sha256",ACCESS_TOKEN_SECRET).update(parsed.signingInput).digest());
  if (parsed.signatureB64.length !== expected.length || !crypto.timingSafeEqual(Buffer.from(parsed.signatureB64), Buffer.from(expected))) return null;
  if (parsed.payload.exp && parsed.payload.exp <= Date.now()/1000) return null;
  return parsed.payload;
}

function json(res,s,b) { const p=JSON.stringify(b); res.writeHead(s,{"content-type":"application/json","content-length":Buffer.byteLength(p)}); res.end(p); }

async function handleTokenExchange(req, res) {
  const chunks=[]; for await(const c of req) chunks.push(c);
  const params = new URLSearchParams(Buffer.concat(chunks).toString());

  if (params.get("grant_type")!==TOKEN_EXCHANGE_GRANT_TYPE) return json(res,400,{error:"unsupported_grant_type"});
  if (params.get("client_assertion_type")!==JWT_SPIFFE_ASSERTION_TYPE) return json(res,400,{error:"unsupported_client_assertion_type"});

  const jwtSvid = params.get("client_assertion");
  const subjectToken = params.get("subject_token");
  const audience = params.get("audience") || "";
  const requestedScopes = (params.get("scope")||"").split(/\s+/).filter(Boolean);
  const now = Math.floor(Date.now()/1000);

  if (!jwtSvid||!subjectToken) return json(res,400,{error:"missing_params"});

  // Check if subject_token is our intermediate HMAC token
  const intermediateToken = verifyHmacToken(subjectToken);
  if (intermediateToken && intermediateToken.token_use === "intermediate") {
    // FINAL exchange: supervisor sends intermediate token + supervisor SVID
    const supervisorSvid = await verifyJwtSvid(jwtSvid, SUPERVISOR_TRUST_DOMAIN_PREFIX);
    if (!hasAudience(intermediateToken, supervisorSvid.sub)) return json(res,403,{error:"audience_mismatch"});

    const finalScopes = requestedScopes.filter(s => !s.endsWith(".write"));
    console.log("FINAL exchange: user="+intermediateToken.sub+" email="+intermediateToken.email+" scope="+finalScopes.join(" ")+" client="+supervisorSvid.sub);

    const finalToken = signToken({
      iss:JWT_SVID_AUDIENCE, sub:intermediateToken.sub, email:intermediateToken.email,
      aud:[audience,"account"], scope:finalScopes.join(" ")+" profile email",
      azp:supervisorSvid.sub, client_id:supervisorSvid.sub,
      token_use:"final", iat:now, exp:now+300
    });
    return json(res,200,{access_token:finalToken,token_type:"Bearer",expires_in:300,scope:finalScopes.join(" ")});
  }

  // INTERMEDIATE exchange: gateway sends user OIDC token + gateway SVID
  const gatewaySvid = await verifyJwtSvid(jwtSvid, GATEWAY_TRUST_DOMAIN_PREFIX);
  let user, email, scope;
  try {
    const oidc = parseJwt(subjectToken).payload;
    user = oidc.preferred_username || oidc.sub || "unknown";
    email = oidc.email || user+"@bank.com";
    scope = oidc.scope || "openid";
  } catch(_) { return json(res,400,{error:"invalid_subject_token"}); }

  console.log("INTERMEDIATE exchange: user="+user+" email="+email+" gateway="+gatewaySvid.sub+" audience="+audience);

  const intToken = signToken({
    iss:JWT_SVID_AUDIENCE, sub:user, email:email,
    aud:[audience], scope:scope,
    azp:gatewaySvid.sub, client_id:gatewaySvid.sub,
    token_use:"intermediate", iat:now, exp:now+300
  });
  return json(res,200,{access_token:intToken,token_type:"Bearer",expires_in:300});
}

http.createServer(async(req,res)=>{
  try{
    if(req.url==="/healthz"){res.writeHead(200);return res.end("ok\n")}
    if(req.method==="POST"&&req.url==="/token")return await handleTokenExchange(req,res);
    return json(res,404,{error:"not_found"});
  }catch(e){console.error("Error:",e.message);return json(res,500,{error:"server_error",message:e.message})}
}).listen(PORT,"0.0.0.0",()=>console.log("bank-demo token exchange issuer on "+PORT));
