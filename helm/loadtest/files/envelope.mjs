// envelope.mjs — sideband envelope construction, decision parsing, and the
// claim/rate helpers. Pure module, imported by the k6 script (inside the
// cluster), the unit tests, and the smoke test (Node). The envelope schema
// mirrors the sibling project's paz-extauthz-adapter buildSidebandEnvelope
// exactly — PAZ's sideband endpoint expects this shape, and field drift
// yields silently vacuous decisions (NOT_APPLICABLE), not errors.

// buildSidebandEnvelope({ method, url, headers, body, sourceIp, sourcePort, httpVersion })
//   -> the PAZ sideband request envelope.
//   headers: plain object; rendered as an array of single-key objects
//            preserving the caller's key casing.
//   body:    string (PAZ expects the raw body as a string).
//   httpVersion: bare protocol version ("1.1"), never "HTTP/1.1".
//   sourcePort: string (text, per the sideband schema).
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

// isPermit(statusCode, parsedBody) -> boolean.
// PAZ signals permit as HTTP 200 with NO embedded `response` object; a 200
// WITH a `response` object is a DENY (the trap: agentgateway's extAuthz
// treats every 2xx as allow — this loader must not). Anything non-200 is
// not a permit.
export function isPermit(statusCode, parsedBody) {
  if (statusCode !== 200) return false;
  return !(parsedBody && typeof parsedBody === "object" && parsedBody.response);
}

// buildClaims({ userIndex, iteration, issuer, mcpAud, userCount })
//   -> the subject-token claim set: the sibling project's permit fixture,
//   with `sub` rotating through synthetic VIP users and a fresh jti per
//   call so no token is ever replayed.
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

// distributeRate(totalRate, agentCount) -> per-agent rate.
// Whole-iteration rounding can distort the aggregate (25/10 -> 3/agent = 30
// total, +20%); fail loudly instead of silently shedding or overloading.
export function distributeRate(totalRate, agentCount) {
  const rate = Math.max(1, Math.round(totalRate / agentCount));
  const drift = Math.abs(rate * agentCount - totalRate) / totalRate;
  if (drift > 0.05) {
    throw new Error(
      `Rate cannot be distributed: ${totalRate}/s over ${agentCount} agents rounds to ` +
      `${rate * agentCount}/s (${(drift * 100).toFixed(1)}% drift > 5%). ` +
      `Choose RATE divisible by AGENTS, or fewer agents.`,
    );
  }
  return rate;
}
