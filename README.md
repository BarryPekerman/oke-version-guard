# oke-version-guard

Keeps a **free-tier Oracle OKE cluster** from silently falling out of OCI's
supported Kubernetes window — the condition under which Oracle starts charging
**$0.10 / cluster / hour**. Runs on GitHub Actions, authenticates to OCI with a
**dedicated least-privilege API key**, and can either alert you or upgrade the
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

### 1. CI identity (one-time, in the `oci-setup` repo)
A dedicated least-privilege user + group + policy live in
`oci-setup/terraform/modules/ci-upgrader`. Enable and apply **only that module**
(never touches the cluster):
```bash
# in oci-setup/terraform, with enable_ci_upgrader=true, ci_domain_url and ci_user_email set:
terraform plan  -target=module.ci_upgrader   # confirm: 0 to destroy
terraform apply -target=module.ci_upgrader
```
Then upload an API key to the created `svc-oke-upgrader-*` user:
```bash
openssl genrsa -out ci_api_key.pem 2048
openssl rsa -in ci_api_key.pem -pubout -out ci_api_key_public.pem
oci iam user api-key upload --user-id <ci-user-ocid> --key-file ci_api_key_public.pem  # prints the fingerprint
```
The user gets a one-time IDCS activation email — **ignore it**; API-key auth
doesn't require console activation.

### 2. Repo variables (Settings → Secrets and variables → Actions)
**Variables:**
| Variable | Example | Notes |
|---|---|---|
| `OCI_REGION` | `il-jerusalem-1` | |
| `OCI_CLUSTER_ID` | `ocid1.cluster.oc1...` | the OKE cluster to guard |
| `OCI_CLI_USER` | `ocid1.user.oc1...` | the CI user OCID |
| `OCI_CLI_TENANCY` | `ocid1.tenancy.oc1...` | |
| `OCI_CLI_FINGERPRINT` | `78:14:…` | from the api-key upload |
| `OCI_CLI_REGION` | `il-jerusalem-1` | |
| `AUTO_UPGRADE` | `true` / `false` | mode toggle |

**Secret:** `OCI_CLI_KEY_CONTENT` = the private key PEM (`ci_api_key.pem`).

The OCI CLI reads these `OCI_CLI_*` values from the environment natively — no
config file needed. The only stored secret is the scoped private key, which can
do **only** the OKE upgrade actions in the policy (verified: it can `ce cluster
get` but is denied `iam` admin calls).

## Files
```
scripts/check-version.sh   classify OK/WARN/URGENT, compute next-minor target
scripts/upgrade.sh         one-minor upgrade + no-surge node cycling + verify
.github/workflows/check.yml    weekly check + issue alert
.github/workflows/upgrade.yml  manual or auto (workflow_run) upgrade
```

## Reuse
Parameterized entirely by repo variables — point `OCI_CLUSTER_ID` at any OKE
cluster (e.g. a second account) with its own scoped API key.
