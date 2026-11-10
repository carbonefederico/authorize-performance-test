import http from 'k6/http';
import encoding from 'k6/encoding';
import { check } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';
// NOTE: no `import crypto from 'k6/crypto'` — that legacy module shadows the
// global WebCrypto `crypto` object that provides `crypto.subtle`.
// envelope.mjs rides in the same ConfigMap and supplies the envelope, the
// claim set, the decision rule, and the rate distribution guard.

import { buildSidebandEnvelope, buildClaims, isPermit, distributeRate } from './envelope.mjs';

const successRate = new Rate('sideband_decision_success');
const latency = new Trend('sideband_decision_latency', true);
const denials = new Counter('sideband_denials');

const required = [
  'PAZ_SIDEBAND_URL', 'SIDEBAND_SHARED_SECRET', 'MCP_AUD',
  'SUBJECT_ISSUER', 'SUBJECT_SIGNING_KEY',
];
for (const key of required) {
  if (!__ENV[key]) {
    throw new Error(`Missing required environment variable: ${key}`);
  }
}

const totalRate = Number(__ENV.TOTAL_RATE || __ENV.RATE || 50);
const agentCount = Number(__ENV.AGENT_COUNT || 1);
const agentIndex = Number(__ENV.AGENT_INDEX || 0);
if (agentIndex >= agentCount) {
  throw new Error(`AGENT_INDEX (${agentIndex}) must be less than AGENT_COUNT (${agentCount})`);
}
// Each agent drives its share of the total rate; drift over 5% fails loudly
// (envelope.mjs) instead of silently shedding or overloading.
const rate = distributeRate(totalRate, agentCount);

const preAllocatedVUs = Number(__ENV.PRE_ALLOCATED_VUS || 25);
const maxVUs = Number(__ENV.MAX_VUS || 200);
const p95Ms = Number(__ENV.P95_MS || 500);
const minimumSuccessRate = Number(__ENV.SUCCESS_RATE || 0.99);
const userCount = Number(__ENV.SUBJECT_USER_COUNT || 100);
const subjectIssuer = __ENV.SUBJECT_ISSUER;
const mcpAud = __ENV.MCP_AUD;
const sidebandUrl = __ENV.PAZ_SIDEBAND_URL;
const sharedSecret = __ENV.SIDEBAND_SHARED_SECRET;
const requestTimeout = __ENV.REQUEST_TIMEOUT || '30s';

// The MCP audience doubles as the envelope URL's origin: the policies gate
// on this resource identifier, so the envelope must present it. k6's init
// context has no URL global — derive the host by string surgery.
const mcpHost = mcpAud.replace(/^https?:\/\//, '').split('/')[0];
const envelopeUrl = mcpAud;

// k6's WebCrypto needs the DER bytes of the PKCS#8 key: strip PEM armor and
// base64-decode once at init time.
const pkcs8Der = new Uint8Array(
  encoding.b64decode(
    __ENV.SUBJECT_SIGNING_KEY
      .replace(/-----[^-]+-----/g, '')
      .replace(/\s+/g, ''),
    'std',
  ),
);
let signingKeyPromise = null;
function getSigningKey() {
  if (!signingKeyPromise) {
    signingKeyPromise = crypto.subtle.importKey(
      'pkcs8',
      pkcs8Der,
      { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
      false,
      ['sign'],
    );
  }
  return signingKeyPromise;
}

function b64urlJson(object) {
  return encoding.b64encode(JSON.stringify(object), 'rawurl');
}

// Build and sign one RS256 subject token (kid perf-subject-key — the name of
// the trusted certificate PAZ validates against). Returns a promise
// resolving to the compact JWT.
async function buildSubjectToken(vu, iter) {
  const claims = buildClaims({
    userIndex: (vu + iter) % userCount,
    iteration: iter,
    issuer: subjectIssuer,
    mcpAud,
    userCount,
  });
  const signingInput = `${b64urlJson({ alg: 'RS256', typ: 'JWT', kid: 'perf-subject-key' })}.${b64urlJson(claims)}`;
  const key = await getSigningKey();
  const signature = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    key,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${encoding.b64encode(signature, 'rawurl')}`;
}

// One JSON-RPC tools/call for the read tool — the measured workload's body.
function rpcBody(userIndex, iter) {
  return JSON.stringify({
    jsonrpc: '2.0',
    method: 'tools/call',
    params: {
      name: 'get_portfolio',
      arguments: {
        customerId: `CUST-${String((userIndex % userCount) + 1).padStart(5, '0')}`,
        txn: `txn-${iter}`,
      },
    },
    id: iter,
  });
}

export const options = {
  insecureSkipTLSVerify: (__ENV.INSECURE_SKIP_TLS_VERIFY || 'false') === 'true',
  discardResponseBodies: false,
  scenarios: {
    // Warmup: full-rate ramp that fills connection pools and lets the JVM
    // JIT-compile hot paths. Its traffic is tagged and excluded from the
    // measured thresholds; the measured scenario starts after it finishes.
    warmup: {
      executor: 'constant-arrival-rate',
      rate,
      timeUnit: '1s',
      duration: __ENV.WARMUP || '30s',
      preAllocatedVUs,
      maxVUs,
      gracefulStop: '5s',
      exec: 'warmupIteration',
      tags: { phase: 'warmup' },
      startTime: '0s',
    },
    sideband_decision: {
      executor: 'constant-arrival-rate',
      rate,
      timeUnit: '1s',
      duration: __ENV.DURATION || '5m',
      preAllocatedVUs,
      maxVUs,
      gracefulStop: '30s',
      // Starts once the warmup scenario has finished.
      startTime: __ENV.WARMUP || '30s',
      tags: { phase: 'measured' },
    },
  },
  thresholds: {
    // Latency and success gates apply to the MEASURED scenario only
    // (sub-metrics scoped by scenario name); warmup traffic exists to prime
    // the platform and must not gate.
    'sideband_decision_latency{scenario:sideband_decision}': [`p(95)<${p95Ms}`],
    'sideband_decision_success{scenario:sideband_decision}': [`rate>=${minimumSuccessRate}`],
    'http_req_failed{scenario:sideband_decision}': ['rate<0.01'],
    // Dropped iterations invalidate a stress stage: when required concurrency
    // (rate x latency) exceeds maxVUs, k6 silently sheds load and latency
    // looks fine because the excess requests were never sent. Any drop
    // fails the stage.
    dropped_iterations: ['count==0'],
  },
  tags: {
    system_under_test: 'pingauthorize-sideband',
    operation: 'sideband_decision',
  },
};

// Warmup iterations run the same measured path — they warm connections, JIT
// and caches — but their metric points carry phase=warmup so the report can
// exclude them.
export async function warmupIteration() {
  await doDecision(__VU, __ITER);
}

export default async function () {
  await doDecision(__VU, __ITER);
}

async function doDecision(vu, iter) {
  const token = await buildSubjectToken(vu, iter);
  const envelope = buildSidebandEnvelope({
    method: 'POST',
    url: envelopeUrl,
    headers: {
      'content-type': 'application/json',
      accept: 'application/json, text/event-stream',
      authorization: `Bearer ${token}`,
      host: mcpHost,
    },
    body: rpcBody(vu, iter),
    sourceIp: `10.0.0.${(vu % 250) + 1}`,
    sourcePort: 40000 + (iter % 20000),
    httpVersion: '1.1',
  });

  const params = {
    headers: {
      'Content-Type': 'application/json',
      'PDG-TOKEN': sharedSecret,
    },
    tags: { name: 'POST /sideband/request' },
    timeout: requestTimeout,
  };

  const response = http.post(sidebandUrl, JSON.stringify(envelope), params);
  latency.add(response.timings.duration);

  let payload = null;
  try {
    payload = response.json();
  } catch (_) {
    // isPermit treats an unparseable body as not-a-permit; nothing to log.
  }

  const permitted = isPermit(response.status, payload);
  check(response, {
    'PAZ permitted the decision': () => permitted,
  });
  successRate.add(permitted);
  if (!permitted) denials.add(1);
}
