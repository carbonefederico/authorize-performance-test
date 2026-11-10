# PAZ sideband performance test — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and run a k6-driven performance campaign that measures PingAuthorize Server's (PAZ) Sideband API decision path in deployment-package (embedded PDP) mode inside Kubernetes, at 100/250/500 decisions/second.

**Architecture:** k6 agent pods play the gateway (PEP) and POST sideband envelopes directly to a 2-replica PAZ Service; PAZ validates self-signed RS256 tokens against a local trusted certificate and evaluates policies from a `.deploymentpackage` file loaded in-process (no PAP, no store, no JWKS server on the measured path). PAP exists only to build the package once. Campaign tooling (profiles, monitor, reports) is ported from the PF sibling.

**Tech Stack:** Helm 3 + official Ping chart 0.15.0 (PAZ/PAP tag 2607), k6 2.2.0 (grafana/k6), Node ≥ 20 (envelope module, unit tests, smoke), bash + kubectl, python3 (report).

**Spec:** `docs/superpowers/specs/2026-11-10-paz-sideband-perf-design.md` — the plan argues from the spec; executors read both.

## Global Constraints

- Ping image tag **2607** for both PAZ and PAP (2608 breaks standalone bootstrap — sibling values file). Ping chart **0.15.0** from `https://helm.pingidentity.com/`. k6 image **grafana/k6:2.2.0**.
- Topology and resources (spec table): PAZ ×2 StatefulSet requests cpu 2 / memory 3Gi, limits cpu 4 / memory 6Gi, preferred anti-affinity on hostname; PAP ×1 requests cpu 1 / memory 2Gi, limits cpu 2 / memory 4Gi; k6 agents requests cpu 100m / memory 512Mi, limits cpu 4 / memory 2Gi. Ephemeral `/opt/out` (no PVC) for both Ping products. **No JWKS server, no Ingress, no cert-manager.**
- Campaign bound **500 decisions/s** — never run a level above it. Reference levels 100/250/500, `DURATION=5m`, `WARMUP=30s`, `AGENTS=10`, thresholds `P95_MS=500`, `SUCCESS_RATE=0.99`, gates: `dropped_iterations == 0`, achieved ≥ 98%.
- **No Makefile.** Scripts called directly (`./scripts/foo.sh`). Conventional Commits prefixes; **never** any Claude/Anthropic attribution in commits or files.
- Secrets live in `.env` (git-ignored) and cluster Secrets only; profiles hold no secrets.
- All documentation (READMEs, comments, commit messages) in English, full declarative sentences.
- Measured-path sideband envelope schema must match the sibling adapter's `buildSidebandEnvelope` exactly (headers as array of single-key objects, `body` as string, bare `http_version`, `source_port` as text).
- Default namespace `paz-perf`; release names `paz` (Ping chart) and `loadtest`.

## Review Focus

The five inputs a person using this project is most likely to get wrong, with the test that pins each:

1. **A PAZ 200 response carrying an embedded `response` object is a DENY, not a permit** — counting it as success would fake the whole campaign. Pinned by `test/unit/decision.test.mjs` (Task 5).
2. **`RATE` not divisible by `AGENTS` silently distorts the load** — a 5% guard must fail loudly. Pinned by `test/unit/envelope.test.mjs` rate-guard test (Task 5).
3. **Envelope field drift vs the sibling adapter schema** (bare `http_version`, string `source_port`, single-key header objects) silently yields NOT_APPLICABLE decisions. Pinned by envelope unit tests (Task 5).
4. **Policy-targeting constants baked in the snapshot** (`service:AgentGateway`, the MCP audience literal) differ from this stack's instinctive values — wrong values pass vacuously or 403. Pinned by the grep step in Task 3 and the smoke negative test (Task 7).
5. **Monitor scrape fragility must not fail a load run** — `cn=Monitor` discovery runs best-effort and records status, never non-zero-exits the run. Pinned by the graceful-degradation step in Task 8.

---

### Task 1: Project scaffold and key material

**Files:**
- Create: `.gitignore`, `.env.example`, `package.json`, `scripts/common.sh`, `scripts/generate-signing-key.sh`
- Test: (manual — script output checks)

**Interfaces:**
- Produces: `scripts/common.sh` exporting `ROOT_DIR`, `require_command`, and sourcing `.env` + optional `PROFILE` (ported from PF `scripts/common.sh`); `keys/subject-signing.key` (PKCS#8 PEM, git-ignored) and `server-profiles/pingauthorize/instance/server/default/data/perf-subject-cert.pem` (self-signed X.509, committed public material) — later tasks reference both exact paths.

- [ ] **Step 1: Initialize git repo and write `.gitignore`** — ignore: `.env`, `keys/`, `results/`, `node_modules/`, `.DS_Store`. Keep `reports/` tracked (published layer), keep `server-profiles/pingauthorize/instance/server/default/data/perf-subject-cert.pem` tracked, ignore `*.deploymentpackage`? No — the package IS committed (profile needs it); do not ignore it.

- [ ] **Step 2: Write `.env.example`** — copy PF's shape with these names/values:
  `NAMESPACE=paz-perf`, `PAZ_RELEASE=paz`, `LOADTEST_RELEASE=loadtest`, `PING_CHART_VERSION=0.15.0`, `PING_IDENTITY_DEVOPS_USER=`, `PING_IDENTITY_DEVOPS_KEY=`, `PING_IDENTITY_ACCEPT_EULA=YES`, `SERVER_PROFILE_URL=https://github.com/carbonefederico/paz-sideband-perf-profiles.git`, `SERVER_PROFILE_PATH=.` (profiles live at repo root), `SERVER_PROFILE_BRANCH=main`, `PAP_ADMIN_PASSWORD=2FederateM0re`, `SIDEBAND_SHARED_SECRET=` (deploy generates and writes back if empty), `SUBJECT_SIGNING_KEY_FILE=${ROOT_DIR}/keys/subject-signing.key`, `SUBJECT_ISSUER=https://paz-perf-subject`, `SUBJECT_USER_COUNT=100`, `MCP_AUD=https://agentgateway-stack-ag.ping-devops.com/mcp/portfolio` (the audience literal baked in the policy snapshot — see Task 3 Step 3), `PAZ_SIDEBAND_URL=https://paz-pingauthorize:8443/sideband/request`, `RATE=50`, `DURATION=5m`, `WARMUP=30s`, `AGENTS=10`, `PRE_ALLOCATED_VUS=25`, `MAX_VUS=200`, `P95_MS=500`, `SUCCESS_RATE=0.99`, `REQUEST_TIMEOUT=30s`, `INSECURE_SKIP_TLS_VERIFY=true`, `PAP_PORT_FORWARD=18443`.

- [ ] **Step 3: Write `scripts/common.sh`** — port PF's: resolve `ROOT_DIR`, `set -euo pipefail` callers, `require_command`, load `.env` if present, then `profiles/${PROFILE}.env` on top if `PROFILE` is set (profile wins), defaulting `PROFILE` from env.

- [ ] **Step 4: Write `scripts/generate-signing-key.sh`** — idempotent (skips when both files exist; `--force` regenerates): `openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out keys/subject-signing.key`, then `openssl req -x509 -key keys/subject-signing.key -out server-profiles/pingauthorize/instance/server/default/data/perf-subject-cert.pem -days 3650 -subj "/CN=perf-subject-key"`. The certificate CommonName and the JWT header `kid` are both `perf-subject-key`.

- [ ] **Step 5: Write `package.json`** — `{ "type": "module", "scripts": { "test": "node --test test/unit/" } }`, no runtime dependencies (k6 and node:crypto cover everything).

- [ ] **Step 6: Verify and commit** — run `./scripts/generate-signing-key.sh` twice (second run is a no-op), `openssl x509 -in server-profiles/pingauthorize/instance/server/default/data/perf-subject-cert.pem -noout -subject` prints `subject=CN = perf-subject-key`. Commit: `chore: project scaffold, signing key generation, env template`.

### Task 2: Helm chart `helm/paz` (2 PAZ + 1 PAP, embedded-PDP ready)

**Files:**
- Create: `helm/paz/Chart.yaml`, `helm/paz/values.yaml`, `helm/paz/templates/_helpers.tpl`, `helm/paz/templates/secrets.yaml`

**Interfaces:**
- Consumes: `SIDEBAND_SHARED_SECRET`, `PAP_ADMIN_PASSWORD` from `.env` (chart reads them via `--set-string` from deploy scripts, never hardcodes).
- Produces: release `paz` exposing Services `paz-pingauthorize:8443` (HTTPS) and `paz-pingauthorizepap:8443`; container env `SIDEBAND_SHARED_SECRET` on PAZ (from secret) consumed by the dsconfig subst in Task 3; chart values `pingDevopsEnabledToggle` fields `pingauthorize.enabled` / `pingauthorizepap.enabled` so deploy can install PAP-only first.

- [ ] **Step 1: Write `Chart.yaml`** — `apiVersion: v2`, `name: paz`, `version: 0.1.0`, dependency `ping-devops` `0.15.0` repository `https://helm.pingidentity.com/`.

- [ ] **Step 2: Write `values.yaml`** — modeled on the sibling's `agentgateway-stack/values.yaml`:
  ```yaml
  ping-devops:
    global:
      envs: { PING_IDENTITY_ACCEPT_EULA: "YES" }
      image: { tag: "2607" }
      ingress: { enabled: false }
      privateCert: { generate: true }
      license: { secret: { devOps: paz-devops-secret } }
    pingauthorize:
      enabled: false          # deploy flips to true after the package lands
      envs:
        SERVER_PROFILE_URL: ""   # from --set-string (the profile repo)
        SERVER_PROFILE_PATH: "pingauthorize"
      workload:
        type: StatefulSet
        statefulSet: { persistentvolume: { enabled: false } }
      container:
        replicaCount: 2
        resources: { requests: { cpu: "2", memory: 3Gi }, limits: { cpu: "4", memory: 6Gi } }
        env:
          - name: SIDEBAND_SHARED_SECRET
            valueFrom: { secretKeyRef: { name: paz-secrets, key: sideband-shared-secret } }
        affinity:
          podAntiAffinity:
            preferredDuringSchedulingIgnoredDuringExecution:
              - weight: 100
                podAffinityTerm:
                  topologyKey: kubernetes.io/hostname
                  labelSelector: { matchLabels: { app.kubernetes.io/name: pingauthorize, app.kubernetes.io/instance: paz } }
    pingauthorizepap:
      enabled: true
      envs:
        SERVER_PROFILE_URL: ""
        SERVER_PROFILE_PATH: "pingauthorizepap"
      workload: { type: StatefulSet, statefulSet: { persistentvolume: { enabled: false } } }
      container: { resources: { requests: { cpu: "1", memory: 2Gi }, limits: { cpu: "2", memory: 4Gi } } }
    pingdataconsole: { enabled: false }
  ```
  Notes for the implementer: `privateCert.generate: true` is correct here (the sibling disabled it only because its cert-manager template collided with it; we have no cert-manager and the in-cluster listener uses the chart's private cert). `PING_IDENTITY_DEVOPS_USER/KEY` go into `paz-devops-secret` (keys `username`/`password`, created by our templates in Step 3) referenced via `global.license.secret.devOps`. If chart 0.15.0's value keys differ from the sibling's shape (it overrides a subchart, we pin the same version, so they should match), follow the sibling file verbatim as the authority.

- [ ] **Step 3: Write `templates/secrets.yaml`** — a `paz-secrets` Secret with keys `sideband-shared-secret` and `pap-admin-password` (values injected via `--set-string`), and `paz-devops-secret` with keys `username`/`password` (DevOps credentials injected the same way).

- [ ] **Step 4: Add `_helpers.tpl`** only if lint complains about name collisions (default chart naming suffices otherwise — do not add speculative helpers).

- [ ] **Step 5: Verify and commit** — `helm dependency update helm/paz`, `helm lint helm/paz --set-string ping-devops.pingauthorize.envs.SERVER_PROFILE_URL=https://example.invalid/x.git` passes; `helm template paz helm/paz` renders 1 StatefulSet (PAP only, since PAZ is disabled by default). Commit: `feat: paz helm chart (2-node PAZ + PAP, ephemeral storage, embedded-PDP ready)`.

### Task 3: PAZ + PAP server profiles (dsconfig layer, snapshot, hooks)

**Files:**
- Create: `server-profiles/pingauthorize/pd.profile/dsconfig/20-token-validator.dsconfig.subst`, `.../30-embedded-pdp.dsconfig.subst`, `.../40-sideband.dsconfig.subst`, `server-profiles/pingauthorize/instance/server/default/data/.gitkeep` (cert arrives in Task 1; package in Task 6)
- Create: `server-profiles/pingauthorizepap/policies/AgentGatewayPortfolioMCP.SNAPSHOT` (copy from sibling), `server-profiles/pingauthorizepap/hooks/81-install-policies.sh` (copy verbatim), `server-profiles/pingauthorizepap/policies/README.md` (adapted), `server-profiles/README.md`

**Interfaces:**
- Consumes: sibling files at `/Users/fcarbone/Documents/projects/ai/ai-mcp-gateways-paz-integrations/agentgateway/k8s/server-profiles/` (the SNAPSHOT and hook are copied, not rewritten); `perf-subject-cert.pem` (Task 1); `SIDEBAND_SHARED_SECRET` env (subst).
- Produces: PAZ boots with validator `PerfSubjectJWT`, embedded PDP from the package file, sideband endpoint `AgentGateway Portfolio MCP` (service `AgentGateway`, base-path `/mcp`, validator `PerfSubjectJWT`, secret header `PDG-TOKEN`); PAP imports+commits branch `AgentGatewayPortfolioMCP` at boot.

- [ ] **Step 1: Copy PAP profile pieces from the sibling** — `policies/AgentGatewayPortfolioMCP.SNAPSHOT` and `hooks/81-install-policies.sh` byte-for-byte; write a short `policies/README.md` recording that the snapshot is the sibling's full-branch export and the hook imports+commits it into branch `AgentGatewayPortfolioMCP` (keep the sibling README's two contract warnings: import always creates a branch; the PDP serves only committed snapshots).

- [ ] **Step 2: Write `20-token-validator.dsconfig.subst`** — the local trust model replacing JWT-Lab:
  ```
  dsconfig create-trusted-certificate \
      --certificate-name perf-subject-key \
      --set "certificate<${PAZ_CERT_PATH}"
  dsconfig create-access-token-validator \
      --validator-name PerfSubjectJWT \
      --type jwt \
      --set enabled:true \
      --set allowed-signing-algorithm:RS256 \
      --set signing-certificate:perf-subject-key
  ```
  `${PAZ_CERT_PATH}` is the in-container absolute path of `instance/server/default/data/perf-subject-cert.pem` — verify the exact server-root on the running PAZ (`kubectl exec ... ls /opt/staging` / `find / -name perf-subject-cert.pem`) during first deploy and record it in `server-profiles/README.md`; adjust the subst if the profile overlay lands elsewhere. If PAZ's JWT validator ignores `kid` (single-cert mode), nothing else changes; if it requires a `kid` match, the certificate name `perf-subject-key` already equals the token `kid` — confirm at smoke time.

- [ ] **Step 3: Write `30-embedded-pdp.dsconfig.subst`** — the whole point of this stack:
  ```
  dsconfig set-policy-decision-service-prop \
      --set pdp-mode:embedded \
      --set deployment-package:${PAZ_PACKAGE_PATH} \
      --set trust-framework-version:v2
  ```
  `${PAZ_PACKAGE_PATH}` = in-container path of `instance/server/default/data/agentgateway-portfolio-mcp.deploymentpackage` (same server-root verification as Step 2). Verify the property spelling against this image's `dsconfig set-policy-decision-service-prop --help` (docs show `deployment-package` and `deployment-package-path` across versions) and record the winner in `server-profiles/README.md`. `trust-framework-version:v2` matches the sibling's external-mode pin — keep unless the image rejects it.

- [ ] **Step 4: Write `40-sideband.dsconfig.subst`** — adapted from the sibling's `40-agp.dsconfig.subst`: keep the `AGENTGATEWAY-SIDEBAND` secret block verbatim (`--set "shared-secret:${SIDEBAND_SHARED_SECRET}"`, header `PDG-TOKEN`); the endpoint block keeps `service:AgentGateway` and `base-path:/mcp` but points at our validator: `--set access-token-validator:PerfSubjectJWT`. Do NOT copy the sibling's JWT-Lab external-server block. The service name MUST stay `AgentGateway` — the snapshot's top wrapper PolicySet targets it (wrong value = vacuous decisions). Add a monitor-provider stanza if (and only if) the live check in Task 8 Step 3 finds the Gateway Timing providers absent: create `create-monitor-provider --provider-name "Gateway Timing" --type gateway-timing --set enabled:true` and the Request-Type variant — enabled once for the whole campaign (spec decision: every number carries the same overhead, no on/off pairing). Confirm the exact type names against `dsconfig create-monitor-provider --help` on the running PAZ; if the providers ship enabled by default, write no stanza.

- [ ] **Step 5: Grep the snapshot for the policy constants and record them** — `grep -o 'agentgateway-stack-ag.ping-devops.com[^"]*' server-profiles/pingauthorizepap/policies/AgentGatewayPortfolioMCP.SNAPSHOT | sort -u` and `grep -c '"AgentGateway"' ...`. The audience literal found here is `MCP_AUD`'s default (already set in Task 1's `.env.example` — correct it if the grep finds something else). Record both constants in `server-profiles/README.md`.

- [ ] **Step 6: Write `server-profiles/README.md`** — the tree, the deploy order (PAP first, package, push, PAZ), and the three version-specific verifications from Steps 2–3 with their findings. Full sentences.

- [ ] **Step 7: Commit** — `feat: server profiles (embedded-PDP PAZ layer, PAP branch bootstrap)`.

### Task 4: k6 loadtest chart (PF's, renamed and re-pointed)

**Files:**
- Create: `helm/loadtest/Chart.yaml`, `helm/loadtest/values.yaml`, `helm/loadtest/templates/job.yaml`, `helm/loadtest/templates/configmap.yaml`, `helm/loadtest/files/sideband-decision.js`, `helm/loadtest/files/envelope.mjs`

**Interfaces:**
- Consumes: PF's `helm/loadtest/templates/job.yaml` and `values.yaml` (copy and adapt); Task 5's script files (configmap must mount BOTH).
- Produces: indexed Job `loadtest-<runId>` with N pods, each running `k6 run --out json=/out/k6.json /scripts/sideband-decision.js`, env from Secret `paz-loadtest`, `AGENT_INDEX`/`AGENT_COUNT` from the completion index — identical contract to PF's `scripts/run-in-cluster.sh`.

- [ ] **Step 1: Copy PF's job.yaml and values.yaml**, changing only: script filename(s) in the configmap and command, `existingSecret: paz-loadtest`, k6 image pin stays `2.2.0`. Keep the COLLECT_GRACE_SECONDS hold-for-copy mechanism and `backoffLimit: 0` exactly.

- [ ] **Step 2: configmap.yaml** — render BOTH `files/sideband-decision.js` and `files/envelope.mjs` into the ConfigMap (one key per file), mounted at `/scripts`.

- [ ] **Step 3: Verify and commit** — `helm lint helm/loadtest` passes; `helm template loadtest helm/loadtest --set-string runId=test --set agentCount=10` shows an Indexed Job with `completions: 10` and a ConfigMap containing both script keys. Commit: `feat: k6 loadtest chart (indexed job, sideband script mounting)`.

### Task 5: k6 sideband script + shared envelope module + unit tests

**Files:**
- Create: `helm/loadtest/files/envelope.mjs` (pure, node-importable), `helm/loadtest/files/sideband-decision.js` (k6), `test/unit/envelope.test.mjs`, `test/unit/claims.test.mjs`, `test/unit/decision.test.mjs`

**Interfaces:**
- Consumes: the sibling adapter's `buildSidebandEnvelope` (specification, `paz-extauthz-adapter.mjs`) and PF's token-minting pattern (WebCrypto RS256, cached key promise).
- Produces: `buildSidebandEnvelope({ method, url, headers, body, sourceIp, sourcePort, httpVersion })` → the sideband envelope object; `buildClaims({ userIndex, mcpAud, issuer, iteration })` → the token claim set; `isPermit(statusCode, parsedBody)` → boolean. `sideband-decision.js` imports `./envelope.mjs`.

- [ ] **Step 1: Write `test/unit/envelope.test.mjs`** — port the assertions of the sibling's `envelope.test.mjs`: headers render as an array of single-key objects preserving original casing; `http_version` is bare (`"1.1"` not `"HTTP/1.1"`); `source_port` is a string; `body` stays a string; a missing source falls back to `null` (not `"undefined"`). Plus the rate-guard test: distribute rates as PF's script does and assert `RATE=253, AGENTS=10` throws (drift > 5%) while `RATE=250, AGENTS=10` yields 25/agent.

- [ ] **Step 2: Write `test/unit/claims.test.mjs`** — `buildClaims` output has `sub_type: "vip_user"`, `client_id: "customer_support_agent"`, `act: { sub: "customer_support_agent" }`, `scope: "portfolio:read portfolio:write"`, `aud` equal to the passed `mcpAud`, `sub: "vip-user-<NNN>"` zero-padded rotating from `userIndex`, fresh `jti` per call.

- [ ] **Step 3: Write `test/unit/decision.test.mjs`** — `isPermit`: `(200, {})` → true; `(200, { response: { response_code: 403 } })` → **false** (the deny-in-200 trap); `(401, null)` → false; `(502, null)` → false.

- [ ] **Step 4: Run tests to verify they fail** — `npm test` → FAIL (module not found).

- [ ] **Step 5: Implement `envelope.mjs`** — three exports matching the interfaces block; envelope field-for-field identical to the sibling adapter's (this is the spec's Global Constraint — no reinterpretation).

- [ ] **Step 6: Implement `sideband-decision.js`** — PF's structure (warmup + measured constant-arrival-rate scenarios, scenario-scoped thresholds, dropped-iterations gate, rate-distribution guard) with the body swapped: per iteration, mint an RS256 token (kid `perf-subject-key`, claims from `buildClaims`, key from `SUBJECT_SIGNING_KEY` PEM stripped to PKCS#8 DER), build the envelope for `method: POST`, `url: https://<MCP host>/mcp/portfolio` (derive the host from `MCP_AUD`), headers `content-type: application/json`, `accept: application/json, text/event-stream`, `authorization: Bearer <token>`, body = JSON-RPC `tools/call` for `get_portfolio` with args `{ "customerId": "CUST-<userIndex padded>", "txn": "txn-<iteration>" }`; POST to `PAZ_SIDEBAND_URL` with header `PDG-TOKEN: <SIDEBAND_SHARED_SECRET>`; metrics `sideband_decision_latency` (Trend), `sideband_decision_success` (Rate = `isPermit`), `sideband_denials` (Counter, informational); tags `system_under_test: pingauthorize-sideband`, `operation: sideband_decision`. Thresholds scoped `{scenario:sideband_decision}` exactly as PF scopes them.

- [ ] **Step 7: Run tests to verify they pass** — `npm test` → all PASS. Then `k6 inspect helm/loadtest/files/sideband-decision.js` (k6 installed locally, `brew install k6` if needed) exits 0.

- [ ] **Step 8: Commit** — `feat: k6 sideband decision script with envelope unit tests`.

### Task 6: Package build (`scripts/build-package.sh`)

**Files:**
- Create: `scripts/build-package.sh`

**Interfaces:**
- Consumes: PAP API (port-forward `svc/paz-pingauthorizepap:8443` → localhost:`PAP_PORT_FORWARD`), auth `administrator:$PAP_ADMIN_PASSWORD` with headers `x-user-id: administrator`, `X-XSRF-HEADER: ping`, `-k` (self-signed).
- Produces: `server-profiles/pingauthorize/instance/server/default/data/agentgateway-portfolio-mcp.deploymentpackage` — the committed artifact PAZ boots from. Re-runnable (overwrites; uses a fresh package name per run to dodge PAP's duplicate-name errors).

- [ ] **Step 1: Write the script** — self-contained: opens its own port-forward (background, wait-for-port, trap-kill). Sequence, each step asserting HTTP 200/2xx and failing loudly with the response body on error:
  1. `GET /api/version-control/branches` → find branch `AgentGatewayPortfolioMCP` → take its head snapshot id (discover the exact field name from the response; log the branch JSON to stderr on first run for debugging).
  2. `POST /api/snapshot/<headId>/export` body `[]` → response carries the exported snapshot id.
  3. `POST /api/deployment-packages` body `{"name":"agentgateway-portfolio-mcp-<timestamp>","snapshotId":"<from step 2>","decisionNodeId":"a7c4e2d0-8f11-4b5a-9c3d-6e8f2a1b4c7d"}` → package id.
  4. `GET /api/deployment-packages/<id>/data` → write bytes to the target path.
  If any endpoint 404s, print the pivot note from the spec ("pinned PAP lacks the deployment-packages API — fall back to snapshot-export tooling or a newer builder PAP") and exit 2.

- [ ] **Step 2: Verify shape offline as far as possible** — `bash -n scripts/build-package.sh` passes; the decision-node id in the script equals the GDP id pinned in Task 3's constants (Task 3 Step 5). Full behavior verifies against the live PAP in Task 7.

- [ ] **Step 3: Commit** — `feat: one-time deployment-package build script (PAP API sequence)`.

### Task 7: Deploy, verify, smoke

**Files:**
- Create: `scripts/create-secrets.sh`, `scripts/deploy.sh`, `scripts/verify.sh`, `scripts/smoke.mjs`, `scripts/smoke.sh`

**Interfaces:**
- Consumes: chart (Task 2), profiles (Task 3), `build-package.sh` (Task 6), `SERVER_PROFILE_URL` (the profile repo, created in Step 1).
- Produces: running stack; `scripts/smoke.mjs` exports nothing but is the campaign's go/no-go: 3 asserts (permit, garbage-token 401, rotated-sub permit).

- [ ] **Step 1: Sync script for the profile repo** — the profile content lives in THIS repo under `server-profiles/`; the products clone it from the separate repo the owner approved creating. Create `scripts/sync-profile-repo.sh`: rsync `server-profiles/` → `${PROFILE_REPO_DIR}` (default `~/.paz-perf-profile-repo`, git-cloned from `$SERVER_PROFILE_URL`, profile files at the repo root), commit with a message naming the source commit, push. First use requires the owner to have run once: `gh repo create carbonefederico/paz-sideband-perf-profiles --public` and `git clone https://github.com/carbonefederico/paz-sideband-perf-profiles.git ~/.paz-perf-profile-repo`. Every later push is pre-approved (the owner chose the new-repo route).

- [ ] **Step 2: Write `scripts/create-secrets.sh`** — idempotent (create-if-missing): `paz-devops-secret` (DevOps user/key), `paz-secrets` (sideband shared secret — generate `openssl rand -hex 32` and write it back into `.env` when empty, so k6 and PAZ share one value across redeploys; plus `pap-admin-password`), `paz-loadtest` (all env keys the k6 script reads, from `.env`: `PAZ_SIDEBAND_URL`, `SIDEBAND_SHARED_SECRET`, `MCP_AUD`, `SUBJECT_ISSUER`, `SUBJECT_USER_COUNT`, `SUBJECT_SIGNING_KEY` as file content, `RATE`/`AGENTS`/`DURATION`/`WARMUP`/`PRE_ALLOCATED_VUS`/`MAX_VUS`/`P95_MS`/`SUCCESS_RATE`/`REQUEST_TIMEOUT`/`INSECURE_SKIP_TLS_VERIFY` — later overwritten per profile by `run-in-cluster.sh --set-string`).

- [ ] **Step 3: Write `scripts/deploy.sh`** — phases, each echoed:
  - *headroom*: `kubectl describe nodes` allocatable-vs-requested summary per node, echoed before any install — the spec's constraint check (the PF values file documented this cluster as nearly full). Informational: the operator decides whether to proceed.
  - *prep*: sync profile → profile repo, commit, push (this is the pre-approved push); `helm install paz helm/paz` with PAZ **disabled** (default) and `--set-string` profile URL/branch.
  - *package*: wait for PAP Ready; `./scripts/build-package.sh`.
  - *runtime*: sync + commit + push profile repo again (now includes the package and cert); `helm upgrade paz helm/paz --set ping-devops.pingauthorize.enabled=true ...`; wait for both PAZ pods Ready.
  Idempotent per phase (`helm upgrade` semantics throughout; `helm install` skips when the release already exists).

- [ ] **Step 4: Write `scripts/verify.sh`** — asserts exactly: 2 PAZ pods Running+Ready, 1 PAP pod Ready, Service `paz-pingauthorize` exists on 8443; prints each PAZ pod's node (anti-affinity check). Non-zero on any miss.

- [ ] **Step 5: Write `scripts/smoke.mjs` + `scripts/smoke.sh`** — the user port-forwards (`kubectl -n paz-perf port-forward svc/paz-pingauthorize 18443:8443`) as in PF; `smoke.sh` wraps with preflight checks (port open?) then runs `smoke.mjs` with `PAZ_SIDEBAND_URL=https://localhost:18443/sideband/request`, `INSECURE_SKIP_TLS_VERIFY=true` (node `NODE_TLS_REJECT_UNAUTHORIZED=0` for this script only). `smoke.mjs` asserts, in order: (a) valid vip_user token → HTTP 200, no `response` object (permit — this also settles the rotated-`sub` question, since it uses `vip-user-001`); (b) garbage token → HTTP 200 with `response.response_code == 401` (a positive policy verdict — proves the validator is live, per the sibling's helm-test insight); (c) a second valid token with `sub: vip-user-042` → permit (rotation confirmed). Exit 1 on any miss, printing the decision JSON (redact nothing — lab tokens only).

- [ ] **Step 6: Live verification (cluster time)** — run `./scripts/deploy.sh prep && ./scripts/deploy.sh package && ./scripts/deploy.sh runtime`, then `./scripts/verify.sh`, then smoke via port-forward. Expected: 3/3 smoke asserts pass; PAZ logs show the embedded package loaded (grep `deployment` in `kubectl logs` PAZ pod, record the line in `server-profiles/README.md`'s verification section). Any dsconfig property spelling fix discovered here lands in Task 3's files and re-runs deploy.

- [ ] **Step 7: Commit** — `feat: deploy, verify, smoke pipeline (PAP-first package bootstrap)`.

### Task 8: Campaign runner, monitor, monitor scrape

**Files:**
- Create: `scripts/run-in-cluster.sh`, `scripts/monitor.sh`, `scripts/scrape-monitor.sh`
- Modify: none (PF's versions are the base; port into this repo)

**Interfaces:**
- Consumes: PF's `run-in-cluster.sh`/`monitor.sh` (copy and adapt); loadtest chart (Task 4); `paz-loadtest` Secret (Task 7).
- Produces: `results/<run_id>/` containing `env.json`, per-agent `k6.json` + logs, `monitor-paz-<pod>.json` (cn=Monitor scrape) — the exact inputs Task 9's report reads.

- [ ] **Step 1: Port `run-in-cluster.sh`** — change only: label selectors `app.kubernetes.io/name=pingauthorize` for the pod inventory in `env.json` (list both PAZ pods with node + startTime), profile passthrough identical to PF (profile wins over `.env`), threshold echo identical.

- [ ] **Step 2: Port `monitor.sh`** — unchanged except namespace variable naming; writes `results/pod-usage-<UTC>.csv` (5s cadence, per-pod and per-node CPU/memory).

- [ ] **Step 3: Write `scripts/scrape-monitor.sh`** — best-effort, never fails a run: for each PAZ pod, `kubectl exec <pod> -- bin/ldapsearch --baseDN cn=monitor --searchScope sub "(cn=*Gateway*)" "*" "+"` (bindDN `cn=Directory Manager`, password from the chart's admin secret), output to `results/<run_id>/monitor-paz-<pod>.json` (ldif→json via python3 one-liner); on empty result or exec failure, write a status marker file instead and exit 0. Record discovered entry DNs in `server-profiles/README.md` on first success (the Review-Focus item: scrape failure must not fail the run).

- [ ] **Step 4: Verify** — `bash -n` all three; dry-run `run-in-cluster.sh` against a namespace with no release shows its loud preflight failure (no cluster write). Commit: `feat: campaign runner, pod monitor, cn=Monitor scraper`.

### Task 9: Report generator + profiles + README

**Files:**
- Create: `scripts/generate-report.py`, `profiles/stage-100.env`, `profiles/stage-250.env`, `profiles/stage-500.env`, `profiles/agents.env`, `README.md`
- Modify: none

**Interfaces:**
- Consumes: PF's `generate-report.py` (copy and adapt); Task 8's `results/<run_id>/` contract.
- Produces: `results/<run_id>/report.html` + `summary.json` (pooled latency columns, achieved-vs-target, verdict, monitor deltas); the four profiles; the README.

- [ ] **Step 1: Write the four profiles** — PF's exact shape with our env names: `AGENTS=10`, `RATE=100|250|500`, `DURATION=5m`, `WARMUP=30s`, `PRE_ALLOCATED_VUS=25`, `MAX_VUS=60`, `P95_MS=500`, `SUCCESS_RATE=0.99`, `INSECURE_SKIP_TLS_VERIFY=true`, `SUBJECT_ISSUER=https://paz-perf-subject`, `SUBJECT_USER_COUNT=100`, `MCP_AUD=<from .env — do not override in profile>`, comments noting the 500/s campaign bound.

- [ ] **Step 2: Adapt `generate-report.py`** — changes vs PF's: metric names (`sideband_decision_*`), SUT pods = 2 PAZ pods (label `pingauthorize`) instead of 2 engines, add a monitor-delta section (parse `monitor-paz-*.json`: Gateway Timing phase counters/durations between this run's scrape and the previous run's, labeled as since-restart totals), title/labels say "PAZ sideband decision". Everything else (pooled-latency window logic, threshold gates, generator-health gates, chart panels) stays PF's.

- [ ] **Step 3: Write `README.md`** — full sentences per the documentation style rule. Sections: what this measures and why (deployment-package/embedded-PDP rationale, spec link); architecture (the mermaid from the spec, JWKS-free note); the campaign protocol (PF's, verbatim: 3 ascending rounds, median-by-p95, gates, bound, warmup-discard); quick start (`generate-signing-key.sh` → create profile repo once → `deploy.sh` → `verify.sh` → smoke → `monitor.sh` + `run-in-cluster.sh PROFILE=stage-100` … → `generate-report.py`); benchmark assumptions (static single signing key / no rotation pickup; `MCP_AUD` is the snapshot's constant; monitor providers on for the whole campaign; shared-cluster co-tenancy); repo layout. Reference table placeholder to fill after the campaign.

- [ ] **Step 4: Verify and commit** — `python3 scripts/generate-report.py --help` exits 0 against a synthetic `results/` fixture directory (create one under `/tmp`, not the repo); profiles lint via `bash -n`. Commit: `feat: report generator, load profiles, README`.

### Task 10: Cleanup + uninstall + final validation

**Files:**
- Create: `scripts/uninstall.sh`, `scripts/validate.sh`

**Interfaces:**
- Consumes: everything above.
- Produces: the project's front door (`validate.sh`) and teardown (`uninstall.sh`).

- [ ] **Step 1: Write `scripts/uninstall.sh`** — `helm uninstall loadtest paz` (keeps namespace and Secrets, PF-style); optional `--purge-secrets` flag deletes the three secrets.

- [ ] **Step 2: Write `scripts/validate.sh`** — runs, in order: `npm test`; `helm lint helm/paz` and `helm lint helm/loadtest`; `k6 inspect` the script; `bash -n` every script; `openssl x509 -noout` on the committed cert. Print a one-line PASS/FAIL per check.

- [ ] **Step 3: Full local run** — `./scripts/validate.sh` → all PASS.

- [ ] **Step 4: Commit** — `chore: uninstall and validate scripts` — then the campaign itself runs per the README (cluster work, not plan work).
