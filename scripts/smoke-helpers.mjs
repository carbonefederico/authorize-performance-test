// smoke-helpers.mjs — Node-side RS256 signing and envelope building for the
// smoke test. The envelope logic mirrors helm/loadtest/files/envelope.mjs
// (kept identical on purpose: the smoke test must produce exactly what the
// load generator produces); the k6 script cannot be imported directly because
// it uses k6 globals.
import { createSign } from "node:crypto";

export function buildSidebandEnvelope({
  method = "POST",
  url,
  headers = {},
  body = null,
  sourceIp = null,
  sourcePort = null,
  httpVersion = "1.1",
}) {
  return {
    source_ip: sourceIp ?? null,
    source_port: sourcePort != null ? String(sourcePort) : null,
    method,
    url,
    http_version: String(httpVersion).replace(/^HTTP\//, ""),
    headers: Object.entries(headers).map(([name, value]) => ({ [name]: String(value) })),
    body,
  };
}

export function buildClaims({ userIndex, iteration, issuer, mcpAud, userCount = 100 }) {
  const now = Math.floor(Date.now() / 1000);
  const user = String((userIndex % userCount) + 1).padStart(3, "0");
  return {
    iss: issuer,
    sub: `vip-user-${user}`,
    sub_type: "vip_user",
    client_id: "customer_support_agent",
    aud: mcpAud,
    scope: "portfolio:read portfolio:write",
    act: { sub: "customer_support_agent" },
    iat: now,
    exp: now + 300,
    jti: `${userIndex}-${iteration}-${now}`,
  };
}

function b64url(buffer) {
  return Buffer.from(buffer).toString("base64url");
}

export async function signToken(signingKeyPem, claims) {
  const signer = createSign("RSA-SHA256");
  signer.update(`${b64url(Buffer.from(JSON.stringify({ alg: "RS256", typ: "JWT", kid: "perf-subject-key" })))}.${b64url(Buffer.from(JSON.stringify(claims)))}`);
  const signature = signer.sign(signingKeyPem);
  return `${b64url(Buffer.from(JSON.stringify({ alg: "RS256", typ: "JWT", kid: "perf-subject-key" })))}.${b64url(Buffer.from(JSON.stringify(claims)))}.${b64url(signature)}`;
}
