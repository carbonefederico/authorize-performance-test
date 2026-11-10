import { test } from "node:test";
import assert from "node:assert/strict";
import { buildSidebandEnvelope, distributeRate } from "../../helm/loadtest/files/envelope.mjs";

test("headers render as single-key objects preserving caller casing", () => {
  const envelope = buildSidebandEnvelope({
    url: "https://host/mcp/portfolio",
    headers: { "Content-Type": "application/json", authorization: "Bearer t" },
  });
  assert.deepEqual(envelope.headers, [
    { "Content-Type": "application/json" },
    { authorization: "Bearer t" },
  ]);
});

test("http_version is the bare protocol version, never HTTP/-prefixed", () => {
  assert.equal(buildSidebandEnvelope({ url: "u", httpVersion: "HTTP/1.1" }).http_version, "1.1");
  assert.equal(buildSidebandEnvelope({ url: "u", httpVersion: "1.1" }).http_version, "1.1");
});

test("source_port is rendered as text", () => {
  assert.equal(buildSidebandEnvelope({ url: "u", sourcePort: 51234 }).source_port, "51234");
});

test("body stays a string; absent source fields fall back to null", () => {
  const envelope = buildSidebandEnvelope({ url: "u", body: '{"jsonrpc":"2.0"}' });
  assert.equal(envelope.body, '{"jsonrpc":"2.0"}');
  assert.equal(envelope.source_ip, null);
  assert.equal(envelope.source_port, null);
});

test("rate distribution: divisible rates split evenly", () => {
  assert.equal(distributeRate(250, 10), 25);
});

test("rate distribution: drift over 5% throws loudly", () => {
  // 25/10 rounds to 3/agent = 30 total: +20% drift (the plan's example).
  assert.throws(() => distributeRate(25, 10), /drift/);
});
