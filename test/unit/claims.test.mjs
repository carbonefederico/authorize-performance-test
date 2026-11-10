import { test } from "node:test";
import assert from "node:assert/strict";
import { buildClaims } from "../../helm/loadtest/files/envelope.mjs";

const base = { userIndex: 0, iteration: 1, issuer: "https://paz-perf-subject", mcpAud: "https://host/mcp/portfolio" };

test("claims carry the sibling permit fixture's policy-relevant values", () => {
  const claims = buildClaims(base);
  assert.equal(claims.sub_type, "vip_user");
  assert.equal(claims.client_id, "customer_support_agent");
  assert.deepEqual(claims.act, { sub: "customer_support_agent" });
  assert.equal(claims.scope, "portfolio:read portfolio:write");
  assert.equal(claims.aud, "https://host/mcp/portfolio");
});

test("sub rotates through zero-padded synthetic users from userIndex", () => {
  assert.equal(buildClaims(base).sub, "vip-user-001");
  assert.equal(buildClaims({ ...base, userIndex: 41 }).sub, "vip-user-042");
  assert.equal(buildClaims({ ...base, userIndex: 99 }).sub, "vip-user-100");
});

test("jti is fresh per call (no token replay)", () => {
  const first = buildClaims(base);
  const second = buildClaims({ ...base, iteration: 2 });
  assert.notEqual(first.jti, second.jti);
});
