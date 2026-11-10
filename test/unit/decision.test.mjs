import { test } from "node:test";
import assert from "node:assert/strict";
import { isPermit } from "../../helm/loadtest/files/envelope.mjs";

test("200 without an embedded response object is a permit", () => {
  assert.equal(isPermit(200, {}), true);
});

test("200 WITH an embedded response object is a DENY, not a permit", () => {
  assert.equal(isPermit(200, { response: { response_code: 403 } }), false);
});

test("401 is not a permit", () => {
  assert.equal(isPermit(401, null), false);
});

test("502 is not a permit", () => {
  assert.equal(isPermit(502, null), false);
});
