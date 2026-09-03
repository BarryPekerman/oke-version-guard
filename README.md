# oke-version-guard

Keeps a **free-tier Oracle OKE cluster** from silently falling out of OCI's
supported Kubernetes window — the condition under which Oracle starts charging
**$0.10 / cluster / hour**. Runs on GitHub Actions, authenticates to OCI with
**keyless OIDC** (no stored API key), and can either alert you or upgrade the
cluster automatically.

## How it works

```
weekly cron ──► check-version.sh ──► OK  → done
                                    │
                                    ├► WARN  (oldest supported minor)
                                    └► URGENT(already unsupported → billing)
                                            │
                          opens/updates a GitHub issue,  and — if AUTO_UPGRADE=true —
                          triggers upgrade.yml:
                                            │
              control plane → node-pool template → cycle nodes ONE AT A TIME
              (drain → delete-node, no surge) → verify /readyz → comment + close issue
```

### Free-tier-safe by design
- **No surge during node cycling.** Nodes are removed *before* replacements are
  created (`delete-node --is-decrement-size false`), so the cluster never exceeds
  the 4-OCPU Always-Free ceiling. Brief single-node capacity, **zero cost**.
- **One minor per run.** OKE refuses to skip minors; the script steps exactly one.
- **DB-safe.** Data on OCI **block-volume PVCs** detaches/reattaches across the
  cycle and survives. Optional pre-upgrade volume **snapshot** as a safety net.
- **Fails closed.** Any unhealthy state (cluster not ACTIVE, a node not Ready,
  bad `/readyz`, unhealthy pods) aborts before touching anything.

## Modes
Set the repo variable `AUTO_UPGRADE`:
- `true`  → **fully automatic**: check then upgrade, unattended.
- `false` → **check + notify only**: you run *OKE upgrade* manually from the Actions tab.

## Setup

### 1. OIDC federation (one-time, in the `oci-setup` repo)
The trust/group/policy live in `oci-setup/terraform/modules/oidc`. Enable and apply
**only that module** (never touches the cluster):
```bash
# in oci-setup/terraform, with enable_oidc=true and the oidc_* vars set:
terraform plan  -target=module.oidc   # confirm: 0 to destroy
terraform apply -target=module.oidc
```
`oidc_github_subject` must be `repo:BarryPekerman/oke-version-guard:ref:refs/heads/main`.

### 2. Repo variables (Settings → Secrets and variables → Actions → Variables)
| Variable | Example | Notes |
|---|---|---|
| `OCI_REGION` | `il-jerusalem-1` | |
| `OCI_CLUSTER_ID` | `ocid1.cluster.oc1...` | the OKE cluster to guard |
| `OCI_DOMAIN_URL` | `https://idcs-xxxx.identity.oraclecloud.com` | your identity domain |
| `OCI_CLIENT_ID` | `<domain OAuth client id>` | client tied to the trust (see below) |
| `AUTO_UPGRADE` | `true` / `false` | mode toggle |

No **secrets** are needed — auth is keyless via OIDC.

### 3. ⚠️ Finalize the token exchange (validate once)
`scripts/oci-auth.sh` follows Oracle's documented UPST token-exchange flow, but the
domain side needs an **OAuth client** whose `client_id` is listed in the trust's
`oauth_clients`, and the request/audience must match what your identity domain
expects. **This is the one piece to test end-to-end on the first manual run** —
trigger *OKE version check* by hand and confirm the auth step succeeds; adjust
`OIDC_AUDIENCE` / `OCI_CLIENT_ID` if the exchange is rejected. Everything else
(version logic, upgrade, node cycling) is provider-stable.

## Files
```
scripts/check-version.sh   classify OK/WARN/URGENT, compute next-minor target
scripts/upgrade.sh         one-minor upgrade + no-surge node cycling + verify
scripts/oci-auth.sh        GitHub OIDC → OCI UPST token exchange (keyless)
.github/workflows/check.yml    weekly check + issue alert
.github/workflows/upgrade.yml  manual or auto (workflow_run) upgrade
```

## Reuse
Parameterized entirely by repo variables — point `OCI_CLUSTER_ID` / `OCI_DOMAIN_URL`
at any OKE cluster (e.g. a second account) with its own OIDC trust.
