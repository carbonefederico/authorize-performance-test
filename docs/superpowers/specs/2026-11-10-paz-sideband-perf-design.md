# PAZ sideband decision-path performance test — design

## Intent and why

This project measures the performance of PingAuthorize Server (PAZ) acting as
the Policy Decision Point behind an API gateway, in a Kubernetes cluster. The
gateway is simulated: the load generator plays the gateway's role (the Policy
Enforcement Point) and calls PAZ's Sideband API exactly as a gateway
integration would, one authorization request per call. The measurement covers
decision latency, achieved throughput, error rate, and PAZ pod resource
consumption at fixed reference load levels.

The reason this campaign exists is the integration-model change between our
earlier work and production. The sibling project
`ai-mcp-gateways-paz-integrations` deployed PAZ in **external PDP mode**: the
Sideband API endpoint resolved policies through PAP on every decision (PAP
wired as an external server pinned to a policy branch). Production deployments
instead use **deployment packages**: the policy state from a specific, versioned
commit is exported as an immutable bundle and loaded **into the PAZ process
itself** (embedded PDP mode). Ping's documentation states that embedded PDP
mode reduces decision request/response latency compared with an external PDP.
PAP becomes a build-time authoring tool only, and is off the decision path.
This campaign measures PAZ in that deployment-package configuration, so the
numbers describe the production integration model rather than the demo one.

Two sibling projects supply the raw material, and this design deliberately
reuses their working machinery instead of inventing new:

- **`ai-mcp-gateways-paz-integrations` (agentgateway folder)** — the K8s PAZ
  topology (PAZ + PAP from the official Ping chart, standalone PAZ with
  embedded store and ephemeral `/opt/out`), the sideband endpoint dsconfig
  layer (shared secret, `PDG-TOKEN` header, `service:AgentGateway`,
  `base-path:/mcp`, JWT access-token validator), the policy snapshot
  (`AgentGatewayPortfolioMCP.SNAPSHOT`, a full branch including the Global
  Decision Point with children [Token Validation, Portfolio set]), and the
  exact sideband envelope shape the gateway integration produces.
- **`pingfederate-token-exchange-perf`** — the campaign protocol and tooling:
  k6 in-cluster load generation (N parallel agent pods, constant-arrival-rate,
  warmup + measured scenarios), self-signed RS256 subject tokens validated
  against an in-cluster JWKS server, load profiles, the run-directory layout,
  the pod-usage monitor, the HTML report generator, and the documented
  measurement protocol (three ascending rounds, median run by p95,
  generator-health gates, fixed campaign bound).

## Goals

- Characterize the PAZ Sideband API decision path in deployment-package
  (embedded PDP) mode at reference levels of **100, 250, and 500
  decisions/second**, each measured over a five-minute steady window with a
  30-second warmup, three ascending rounds (100 → 250 → 500, repeated three
  times), reporting the median run of the three selected by measured p95.
- Report, per reference level: end-to-end sideband call latency (p50, p90,
  p95, p99, max) measured client-side by k6; achieved rate versus target rate;
  success rate; and PAZ pod CPU and memory during the window.
- Capture **server-side ground truth** from PAZ's Gateway Timing and Gateway
  Request Type Timing monitor providers (`cn=Monitor` over LDAP) so
  client-side latency can be split into transport versus PAZ processing time.
- Run against a fixed topology of **2 PAZ nodes** sized to mirror the PF
  campaign's engine sizing (see Decided decisions), with the load generated
  from inside the cluster.

## Non-goals

This campaign shares the PF project's scope discipline; the following are
deliberately out, and the results support no conclusions about them:

- **No A/B comparison against external PDP mode.** The user decided this
  campaign measures deployment-package mode only. Quantifying the gain over
  the sibling's PAP-branch mode would require a second campaign; nothing here
  claims it.
- **No saturation, failure, or recovery behavior.** Reference levels are fixed
  points, measured as-is; no level is run to failure. 500 decisions/second is
  the campaign bound, exactly as in the PF campaign, because the cluster is
  shared with workloads this project does not own.
- **No production rollout mechanics.** No deployment-package store (S3/Azure/
  filesystem store with polling), no signed packages, no trust-store
  configuration. The package is a file shipped in the server profile (see
  Decided decisions). Rollout mechanics would be an operations test, not a
  decision-path performance test.
- **No deny-path measurement.** One measured workload exists (the permit hot
  path). Denials, challenges, and human-in-the-loop flows are policy-correct
  in the sibling project already and add nothing to a throughput
  characterization.
- **No gateway in the measured path.** There is no agentgateway, no
  paz-extauthz-adapter, no MCP backend. k6 plays the gateway directly. The
  measured hop is exactly the hop a gateway integration adds: the sideband
  request and PAZ's decision. Adding a real gateway later would measure the
  gateway too, which is a different question.
- **No autoscaling.** The PAZ topology is fixed at 2 nodes.

## Anti-goals (what would make this a failure even if it works)

- Publishing numbers whose provenance is unclear. Every latency column must
  come from the same measured window, warmup excluded, with the run's
  generator-health gates recorded (zero dropped iterations, achieved rate
  ≥ 98%, success rate ≥ threshold), as in the PF README.
- Letting PAP or any external policy source sit on the measured path. If a
  decision involves a PAP round trip, the deployment-package configuration is
  not actually active and the results are invalid for their stated purpose.
- A policy set so trivial that the numbers flatter PAZ. The measured requests
  must exercise the sibling's real policy ladder (token validation, target
  matching, scope and delegation checks), not a one-line permit-all.

## Constraints

- **Target cluster (decided by the owner):** the same cluster the PF campaign
  ran in, with the PF campaign's releases torn down — the namespace is
  effectively free for this campaign. The PF project's values file still
  documents the cluster as tightly packed (per-node headroom ~0.1–0.7 CPU
  with the six co-tenant engines resident); the builder must check current
  headroom at deploy time (`kubectl describe nodes`, allocatable vs requested)
  before trusting the 2×PAZ + PAP + 10-agent topology to schedule, and keep
  the k6 agents at the PF project's 100m-request burstable posture if
  headroom is still tight. Co-tenant load during runs remains an uncontrolled
  factor, visible in the node-CPU panels.
- **Profile repository (decided by the owner):** a **new git repository** on
  the owner's GitHub (`carbonefederico/*`), separate from the
  `ai-mcp-gateways-paz-integrations` repo, holding `server-profiles/` for
  this project. Both Ping products clone from it at boot; creating and
  pushing it is an outward-facing action the owner approves explicitly. The
  deploy sequence respects it: PAP + JWKS first, then the package build,
  then commit-and-push of the `.deploymentpackage` before PAZ boots.
- **Shared cluster.** Nodes host co-tenant workloads. This bounds the campaign
  at 500 decisions/second (never run to failure), and co-tenant load shows up
  in the node-CPU panels of the reports as an uncontrolled environmental
  factor, exactly as in the PF campaign.
- **Lab licensing.** Ping DevOps eval credentials; the Ping chart's well-known
  default admin password is acceptable because nothing is exposed publicly.
- **Server profile distribution.** Ping images clone their server profile
  from a git repository at boot. The profile (dsconfig layer + the
  `.deploymentpackage` file) must be pushed to a repository the cluster can
  reach, as in both sibling projects.
- **No Makefile.** Scripts are called directly (`./scripts/...`), per the
  project owner's global working rules.

## Decided decisions

The following are settled with the project owner; a builder should treat them
as requirements, not suggestions.

### Policy deployment: deployment package file in the server profile (option 1)

**Product pin: PAZ and PAP image tag 2607** — the sibling's values file pins
it as the tag the operator's working PAZ deployments run and documents that
2608 breaks standalone-profile bootstrap. Pin both products to 2607 in
`helm/paz/values.yaml` deliberately; changing the pin redoes the package
build and the version-specific verifications below.

The Policy Decision Service runs in embedded PDP mode with the package loaded
from a file shipped inside PAZ's server profile. The runtime configuration has
no PAP dependency, no store, and no polling: the measured path's policy side is
a fixed, committed artifact — the same spirit as the PF project shipping its
bulk-config JSON in the server profile.

Concretely:

1. **One-time package build (PAP up):** deploy PAP once with the sibling's
   bootstrap hook importing `AgentGatewayPortfolioMCP.SNAPSHOT` into its
   branch and committing it. Then, via the PAP API (basic auth
   `administrator:<password>`, headers `X-XSRF-HEADER: ping` and
   `x-user-id`), export the committed snapshot and create the deployment
   package rooted at the branch's Global Decision Point (decision node id
   `a7c4e2d0-8f11-4b5a-9c3d-6e8f2a1b4c7d` — the id the sibling's snapshot
   builder pins), then download the package bytes
   (`POST /deployment-packages` with name + snapshotId + decisionNodeId,
   then `GET /deployment-packages/{id}/data`). The exact API sequence is
   documented at developer.pingidentity.com under Policy Editor
   deployment-package endpoints. If the pinned PAP image turns out not to
   support the deployment-packages API, this design pivots (fall back to
   snapshot-export tooling or a newer PAP used only as the package builder)
   — verify before committing to the sequence.
2. **Deploy order follows the package build:** PAP and the JWKS server deploy
   first, then `scripts/build-package.sh` runs against PAP's API, then the
   downloaded `.deploymentpackage` is committed and pushed to the profile
   repository **before PAZ's first boot** — otherwise PAZ boots with no
   policy package and needs a second deploy to pick it up.
2. **Runtime profile:** the `.deploymentpackage` file ships in PAZ's server
   profile; the dsconfig layer sets the Policy Decision Service to embedded
   PDP mode pointing at that file (`pdp-mode:embedded` plus the
   deployment-package file property — verify the exact property spelling
   against the deployed image's `dsconfig` help, since documentation shows
   both a `deployment-package` and a `deployment-package-path` form across
   versions; also pin `trust-framework-version` to the package's version if
   the property is required in this image).
3. **During load runs PAP stays deployed but idle.** PAZ never reads it in
   embedded mode. Keeping it deployed preserves the ability to rebuild or
   extend the package mid-campaign without a redeploy.

The sideband endpoint dsconfig layer is reproduced from the sibling verbatim
(shared secret created before the Sideband API extension references it;
`PDG-TOKEN` header name; endpoint `AgentGateway Portfolio MCP` with
`service:AgentGateway`, `base-path:/mcp`) with one change: the endpoint's
access-token validator uses PAZ's **local trusted-certificate model** — the
issuer's public signing key is imported once via
`dsconfig create-trusted-certificate` and referenced with `signing-certificate`
on the JWT validator — instead of a remote JWKS fetch (the sibling used the
internet-hosted JWT-Lab). **No JWKS server exists in this stack** (a decision
confirmed with the owner): PF's dedicated JWKS pod represented an
issuer-publishes/verifier-fetches distribution model that campaign set out to
measure; here the question is the decision path, and the local certificate
removes every remote fetch, cache, and refresh behavior from it. The recorded
trade-off: the campaign measures a single static signing key with out-of-band
distribution; `kid`-based rotation pickup is out of scope (PAZ cannot pick up
key rotation without an HTTP JWKS source).

### Topology and sizing (mirrors the PF campaign)

| Component | Replicas | Requests | Limits | Notes |
|---|---|---|---|---|
| PAZ (StatefulSet, ephemeral `/opt/out`) | 2 | cpu 2, memory 3Gi | cpu 4, memory 6Gi | Mirrors PF engines' shape: the user's "4 vCPU each" maps onto the limits; preferred anti-affinity across nodes |
| PAP (StatefulSet) | 1 | cpu 1, memory 2Gi | cpu 2, memory 4Gi | Package authoring only; idle during runs |
| k6 agents (indexed Job) | 10 at load levels | cpu 100m | cpu 4, memory 2Gi | Burstable; monitor CSV records actual usage |

There is no JWKS server: token validation uses PAZ's local
trusted-certificate model (see Policy deployment). Everything is
cluster-internal: no Ingress, no cert-manager, no public DNS.
PAP's console is reached with `kubectl port-forward`. PAZ's Sideband API is
consumed in-cluster over its HTTPS listener with `insecureSkipTLSVerify`
(the lab-TLS posture PF documents; the sibling's adapter instead extracts the
PAZ cert, which k6 does not need).

### The measured workload

One measured operation: a **portfolio read** through the policy ladder. Each
k6 iteration builds the sideband envelope exactly as the sibling's adapter
does — `source_ip`, `source_port`, `method: POST`,
`url: https://<mcp-host>/mcp/portfolio`, bare `http_version`, headers as an
array of single-key objects including
`Authorization: Bearer <fresh token>`, and `body` as a JSON-RPC string — and
POSTs it to `https://<paz-service>/sideband/request` with the `PDG-TOKEN`
header. A 200 response without an embedded `response` object is a permit and
counts as success.

- **Tokens are self-signed RS256 by k6** (WebCrypto, key from
  `keys/subject-signing.key`, kid `perf-subject-key`) and validated by PAZ
  against the in-cluster JWKS server. This is PF's model, transplanted: the
  token issuer is on the measured path only as an HTTPS/LAN JWKS fetch PAZ
  caches, and no external key service adds variance.
- **Claims follow the sibling's permit fixture**:
  `sub_type: "vip_user"`, `client_id: "customer_support_agent"`,
  `act: {"sub": "customer_support_agent"}`, `scope: "portfolio:read
  portfolio:write"`, `aud` set to the MCP resource identifier. `sub` rotates
  through 100 synthetic subjects (`vip-user-001` … `vip-user-100`) and `jti`
  is fresh per iteration, so no token is ever replayed. **The builder must
  verify at smoke-test time that the policies permit with a rotated `sub`** —
  the sibling's fixtures pin `sub: "vip_user"`, and if any policy condition
  pins the literal value, the fallback is a fixed `sub` with fresh `jti` per
  iteration (PAZ keeps no per-subject state on this path, so rotation is a
  replay-prevention nicety, not a load-model requirement).
- **Body**: a JSON-RPC `tools/call` request for the read tool
  (`get_portfolio`) with a small realistic arguments object. The high-band
  approval path (the `tctx` six-field mirror) is not measured in this
  campaign.

### Load model and protocol (PF's, verbatim)

- k6 `constant-arrival-rate` per agent; `RATE` is the total across agents,
  divided evenly with a loud failure on > 5% rounding drift; 30s warmup
  scenario (tagged, excluded from thresholds) followed by the 5-minute
  measured scenario.
- Thresholds applied to the measured scenario only: p95 < 500 ms, success
  ≥ 99%, `http_req_failed` < 1%, and `dropped_iterations == 0` (a dropped
  iteration means the generator shed load — the run is invalid, not "fast").
- Campaign protocol: three ascending rounds of 100 → 250 → 500; the reference
  table reports the median run of the three by measured p95; one throwaway
  sanity run warms a fresh deployment before the first counted round;
  gate-failing runs are rerun and both attempts recorded.
- Profiles `stage-100.env`, `stage-250.env`, `stage-500.env` fully describe
  their runs, exactly like PF's.

### Measurement and evidence

- **Client side:** per-agent k6 metric streams and end-of-run summaries into
  `results/<run_id>/` (one directory per run, lab-local), pooled-latency
  statistics computed over the measured window only, `env.json` snapshot of
  run settings. The published layer is `reports/` (self-contained HTML per
  run) plus the reference table in the README.
- **Pod resources:** PF's monitor approach — a 5-second-cadence CSV of
  per-pod and per-node CPU/memory (`kubectl top`) running for the whole
  campaign.
- **Server side (new vs PF):** an end-of-run scrape of PAZ's `cn=Monitor`
  tree over LDAP (Gateway Timing, Gateway Request Type Timing, Gateway
  Statistics — forward queue size) using the PAZ admin credentials from
  `.env`, saved next to the run's other artifacts. Monitor counters are
  since-server-start, so the scrape records absolute values and the report
  derives deltas between consecutive runs; the builder should verify the
  exact monitor entry DNs on the running deployment
  (`ldapsearch --baseDN cn=monitor "(cn=*Gateway*)"`). **Monitoring posture
  (decided):** if the Gateway Timing providers must be enabled via dsconfig,
  enable them once for the whole campaign so every number carries the same
  overhead — no paired monitoring-on/off runs. If the providers do not exist
  on this image version, drop the transport-versus-processing split and
  record that in the README; the campaign's client-side numbers do not
  depend on it.
- **Report generation:** adapt PF's `generate-report.py` (throughput,
  latency, latency breakdown, PAZ pod and node CPU over time, per-agent
  detail; the monitor-derived deltas added to the summary).

### Repository layout (PF's shape, scripts not Make targets)

```
helm/paz/            Values for the official ping-devops chart: 1 PAP + 2 PAZ
                     StatefulSets, ephemeral /opt/out, lab sizing per the
                     table above; PAZ profile envs include the embedded-PDP
                     dsconfig layer + package file.
helm/loadtest/       The k6 agent chart: indexed Job, N parallel agent pods,
                     each running helm/loadtest/files/sideband-decision.js.
server-profiles/     pingauthorize/ (dsconfig layer: JWKS external server,
                     JWT validator, sideband secret + endpoint, embedded-PDP
                     Policy Decision Service) and pingauthorizepap/ (the
                     sibling's branch-import hook, unchanged). The
                     .deploymentpackage file ships under pingauthorize/.
scripts/             deploy, verify, build-package (the one-time PAP API
                     sequence), smoke, run-in-cluster, monitor, scrape-monitor
                     (cn=Monitor), generate-report.py, uninstall.
profiles/            stage-100/250/500.env + agents.env.
keys/                Subject signing key (git-ignored); the public JWKS is
                     committed into the JWKS server release, as in PF.
results/, reports/   Per-run artifacts; published HTML layer, as in PF.
.env                 Lab credentials and endpoints (git-ignored).
```

## What is left to the builder

- **Exact dsconfig spellings for this image version** (pinned 2607): the
  deployment-package file property on the Policy Decision Service (docs show
  two spellings across versions), whether `trust-framework-version` must be
  pinned, and the PAZ HTTPS listener port the sideband service exposes.
  Verify each against the deployed image's `dsconfig` help and running
  config; record what was found in the server profile's README.
- **The one-time package build script** (`scripts/build-package.sh`): the PAP
  API sequence (export snapshot → create package → download bytes) with the
  sibling's documented headers; it must be re-runnable and must place the
  result in `server-profiles/pingauthorize/`.
- **The PAZ claims check at smoke time**: rotated `sub` versus pinned
  `sub` (see The measured workload), settled with one real permit decision
  and recorded in the README.
- **Monitor entry discovery**: the exact `cn=Monitor` DNs and attributes for
  the Gateway Timing providers on this PAZ version, discovered once and
  recorded in `scripts/scrape-monitor.sh`.
- **Report script adaptation**: PF's `generate-report.py` adjusted for the
  sideband metric names, the second PAZ pod, and the monitor deltas.
- **k6 script details**: envelope construction (reuse the sibling adapter's
  `buildSidebandEnvelope` logic as a specification), connection reuse
  settings, and the success check (200 without an embedded `response`
  object).
