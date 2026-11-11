# Server profiles — PAZ sideband performance stack

The server profiles configure both Ping products at boot. The Ping images
clone this project's GitHub repository (the `SERVER_PROFILE_URL` in `.env`)
and apply `server-profiles/` on every start; nothing is configured by hand.
This profile tree is part of the project repository — there is no separate
profile repo. The stack runs PAZ in **embedded PDP mode from a deployment package
file** — PAP exists only to build that package once and is off the decision
path.

## Tree

```
pingauthorize/            PAZ (the measured node, 2 replicas)
├── pd.profile/dsconfig/
│   ├── 20-token-validator.dsconfig.subst   local trusted-certificate JWT validator (PerfSubjectJWT)
│   ├── 30-embedded-pdp.dsconfig.subst      pdp-mode:embedded + the deployment package file
│   └── 40-sideband.dsconfig.subst          sideband shared secret + endpoint (AgentGateway service, /mcp)
├── hooks/                                  (none — the chart's stock hooks apply the pd.profile layer)
└── instance/server/default/data/
    ├── perf-subject-cert.pem               self-signed public certificate matching the k6 signing key
    └── agentgateway-portfolio-mcp.deploymentpackage   the policy package (built once from PAP)

pingauthorizepap/         PAP (package authoring only; idle during load runs)
├── policies/
│   ├── AgentGatewayPortfolioMCP.SNAPSHOT   the full policy branch, copied from the sibling project
│   └── README.md
└── hooks/81-install-policies.sh            imports + commits the snapshot into branch AgentGatewayPortfolioMCP at boot
```

The policy snapshot and the PAP bootstrap hook are byte-for-byte copies from
the sibling project `ai-mcp-gateways-paz-integrations`
(`agentgateway/k8s/server-profiles/`), because this campaign measures the
same policy ladder the gateway integration uses. The two contracts that cost
the sibling debugging time, both preserved here: importing a snapshot always
creates a NEW branch named in the URL (a taken name 409s), and the PDP serves
only COMMITTED snapshots — the hook commits after import, and PAZ's policy
data comes from the deployment package built on top of that commit.

## Deploy order (scripts/deploy.sh drives this)

1. PAP + JWKS-free runtime deps first: `helm install` with PAZ disabled.
   PAP's hook imports and commits `AgentGatewayPortfolioMCP` at boot.
2. `./scripts/build-package.sh` builds the deployment package from PAP's API
   and writes it into `pingauthorize/instance/server/default/data/`.
3. Commit and push this repository (the runtime phase of deploy.sh does it) so the package and certificate are in the clone the PAZ pods fetch.
4. Enable PAZ (`helm upgrade`): it boots with the package file already in its
   profile and the embedded PDP loads it in-process. PAP stays deployed but
   idle; no decision ever touches it.

## Version-specific verifications (record your findings here)

These three values depend on the pinned image (2607) and the profile overlay
layout. Verify each on first deploy and write what you found under its
heading; adjust the dsconfig files if reality differs.

### In-container server root for profile data files

`${PAZ_CERT_PATH}` (20-token-validator) and `${PAZ_PACKAGE_PATH}`
(30-embedded-pdp) must be the absolute in-container paths of
`instance/server/default/data/*`. Verify on the running PAZ with
`kubectl exec <pod> -- find / -name perf-subject-cert.pem 2>/dev/null`.
Finding (fill in on first deploy):

### Deployment-package property spelling

`dsconfig set-policy-decision-service-prop --help` on the running PAZ —
documentation shows `deployment-package` and `deployment-package-path` across
versions; this profile uses `deployment-package`. Finding (fill in on first
deploy):

### Monitor providers

The Gateway Timing / Gateway Request Type Timing monitor providers may ship
enabled or need a dsconfig stanza on this image. Check
`bin/ldapsearch --baseDN cn=monitor "(cn=*Gateway*)" dn` on the running PAZ;
if absent, add the stanza per the plan's Task 3 Step 4 note (enabled once for
the whole campaign). Finding (fill in on first deploy):

## Policy constants baked in the snapshot

The policy tree targets these literals; the load generator must match them
(changing either side changes what is measured):

- **Service**: `AgentGateway` (the sideband endpoint's `service` property; the
  snapshot's top wrapper PolicySet targets it — 1 occurrence verified by
  grep in the snapshot).
- **MCP audience** (`Constants.Portfolio_MCP Audience`, an attribute constant
  resolver): `https://agentgateway-stack-ag.ping-devops.com/mcp/portfolio`.
  This is `.env`'s `MCP_AUD` default; tokens minted for any other audience
  fail the audience gate.
- **Global Decision Point id** (package root for build-package.sh):
  `a7c4e2d0-8f11-4b5a-9c3d-6e8f2a1b4c7d` (verified present in the snapshot).
