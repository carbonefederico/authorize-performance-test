// smoke-helpers.mjs — Node-side RS256 signing for the smoke test. The
// envelope and claims come from helm/loadtest/files/envelope.mjs directly
// (imported by smoke.mjs) so the smoke test and the load generator share one
// implementation; this module contributes only what k6 cannot (node:crypto
// signing instead of k6's WebCrypto).
import { createSign } from "node:crypto";

function b64url(buffer) {
  return Buffer.from(buffer).toString("base64url");
}

export async function signToken(signingKeyPem, claims) {
  const signer = createSign("RSA-SHA256");
  signer.update(`${b64url(Buffer.from(JSON.stringify({ alg: "RS256", typ: "JWT", kid: "perf-subject-key" })))}.${b64url(Buffer.from(JSON.stringify(claims)))}`);
  const signature = signer.sign(signingKeyPem);
  return `${b64url(Buffer.from(JSON.stringify({ alg: "RS256", typ: "JWT", kid: "perf-subject-key" })))}.${b64url(Buffer.from(JSON.stringify(claims)))}.${b64url(signature)}`;
}
