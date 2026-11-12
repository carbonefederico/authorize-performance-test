// smoke.mjs — the campaign's go/no-go: three real decisions against PAZ.
// Run via scripts/smoke.sh (port-forward must be up). Asserts, in order:
//   (a) a valid vip_user token  -> 200, no embedded response (PERMIT). This
//       also settles the rotated-sub question: the token carries
//       vip-user-001, a rotated value the sibling's fixtures never used.
//   (b) a garbage token         -> 200 WITH response.response_code 401 — a
//       positive policy verdict proving the validator is live (a down
//       validator would yield the same shape for valid tokens).
//   (c) a second valid token with sub vip-user-042 -> permit (rotation).
// Exit 1 on any miss; prints each decision JSON (lab tokens only, nothing
// to redact).
import { signToken } from "./smoke-helpers.mjs";
// The smoke test must produce exactly what the load generator produces, so
// the envelope and claims come from the SAME module the k6 script imports
// (envelope.mjs — unit-tested against the sibling adapter's schema).
// smoke-helpers contributes only the Node-side RS256 signing, which k6
// cannot run (it uses k6's WebCrypto).
import { buildSidebandEnvelope, buildClaims } from "../helm/loadtest/files/envelope.mjs";

const base = {
  sidebandUrl: process.env.PAZ_SIDEBAND_URL,
  secret: process.env.SIDEBAND_SHARED_SECRET,
  issuer: process.env.SUBJECT_ISSUER,
  mcpAud: process.env.MCP_AUD,
  signingKeyPem: process.env.SUBJECT_SIGNING_KEY_PEM,
};

for (const [key, value] of Object.entries(base)) {
  if (!value) {
    console.error(`Missing required environment variable: ${key}`);
    process.exit(1);
  }
}

let failures = 0;
async function decide(label, token, userIndex, iter) {
  const envelope = buildSidebandEnvelope({
    method: "POST",
    url: base.mcpAud,
    headers: {
      "content-type": "application/json",
      accept: "application/json, text/event-stream",
      authorization: `Bearer ${token}`,
      host: base.mcpAud.replace(/^https?:\/\//, "").split("/")[0],
    },
    body: JSON.stringify({
      jsonrpc: "2.0",
      method: "tools/call",
      params: {
        name: "get_portfolio_summary",
        arguments: { customerId: `CUST-${String(userIndex + 1).padStart(5, "0")}`, txn: `txn-${iter}` },
      },
      id: iter,
    }),
    sourceIp: "10.0.0.9",
    sourcePort: "41000",
    httpVersion: "1.1",
  });

  const response = await fetch(base.sidebandUrl, {
    method: "POST",
    headers: { "content-type": "application/json", "PDG-TOKEN": base.secret },
    body: JSON.stringify(envelope),
  });
  const text = await response.text();
  let payload = null;
  try {
    payload = text ? JSON.parse(text) : null;
  } catch {
    payload = null;
  }
  return { status: response.status, payload, label };
}

function report(result, expected) {
  const pass = expected(result);
  if (!pass) failures += 1;
  console.log(`${pass ? "PASS" : "FAIL"} ${result.label}: HTTP ${result.status} ${JSON.stringify(result.payload).slice(0, 300)}`);
}

// (a) valid token, rotated sub vip-user-001 -> permit
{
  const claims = buildClaims({ userIndex: 0, iteration: 1, issuer: base.issuer, mcpAud: base.mcpAud });
  const token = await signToken(base.signingKeyPem, claims);
  report(await decide("(a) valid vip-user-001 token", token, 0, 1),
    (r) => r.status === 200 && r.payload && !r.payload.response);
}

// (b) garbage token -> 200 with an embedded denial whose response_code is
// "401" (the validator rejected the token; PAZ serializes the embedded
// response_code as a string). A down validator would permit or deny without
// this shape, so the assert proves the validator is live.
{
  const token = "garbage.token.value";
  report(await decide("(b) garbage token", token, 1, 2),
    (r) => r.status === 200 && String(r.payload?.response?.response_code) === "401");
}

// (c) second valid token, rotated sub vip-user-042 -> permit
{
  const claims = buildClaims({ userIndex: 41, iteration: 3, issuer: base.issuer, mcpAud: base.mcpAud });
  const token = await signToken(base.signingKeyPem, claims);
  report(await decide("(c) valid vip-user-042 token", token, 41, 3),
    (r) => r.status === 200 && r.payload && !r.payload.response);
}

process.exit(failures === 0 ? 0 : 1);
