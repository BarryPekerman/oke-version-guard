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
                                    ├► PATCH (newer patch of current minor exists)
                                    ├► WARN  (oldest supported minor)
                                    └► URGENT(already unsupported → billing)
                                            │
              opens/updates a GitHub issue (assigned to + @mentioning the owner,
              so every alerting run notifies), and — if AUTO_UPGRADE=true —
              triggers upgrade.yml:
                                            │
              control plane → node-pool templates → cycle nodes ONE AT A TIME
              (drain → delete-node, no surge) → verify /readyz + node versions
              → comment + close issue
```

### Free-tier-safe by design
- **No surge during node cycling.** Nodes are removed *before* replacements are
  created (`delete-node --is-decrement-size false`), so the cluster never exceeds
  the 4-OCPU Always-Free ceiling. Brief single-node capacity, **zero cost**.
- **One step per run.** The target is always the **newest patch** of either the
  current minor (PATCH, or URGENT when a patch fixes it) or the next minor
  (WARN/URGENT). OKE refuses to skip minors; `upgrade.sh` rejects any target that
  isn't supported, newer, and at most one minor up.
- **DB-safe.** Data on OCI **block-volume PVCs** detaches/reattaches across the
  cycle and survives. Before upgrading, volumes **attached to cluster nodes** are
  backed up (opt out with the `snapshot` input on manual runs). Only the newest
  `pre-upgrade-*` backup per volume is kept — Always Free allows 5 volume backups.
- **Fails closed.** Any unhealthy state (cluster not ACTIVE, a node not Ready,
  bad `/readyz`, Pending/crash-looping pods) aborts before touching anything; a
  failed drain uncordons the node and aborts before deleting it.
- **OKE worker images.** Pools booting an OKE image (`…-OKE-1.34.2-…`) can't take a
  version-only update, so the node-pool step swaps to the newest OKE image for the
  target on the same OS line, keeping the boot volume size.
- **Resumable.** If a run dies midway, re-run *OKE upgrade* with the same target:
  steps already at that version (control plane, templates, nodes) are skipped.

## Track record

**2026-10-10: v1.34.2 → v1.35.2 on the live cluster** (2 × A1 nodes, a MediaWiki
on a block-volume PVC). The check flagged WARN (oldest supported minor); the
upgrade took two runs the same evening, and each failure stopped safely:

1. **Run 1:** control plane upgraded, then OCI rejected the node-pool update
   with *409 "Cannot update Kubernetes version which has already been set by
   OKE worker node image"*. Nodes booted from OKE images pin their version.
   Stopped before touching a node. **Fix:** swap the pool to the newest OKE
   image for the target version.
2. **Run 2:** pool updated, both nodes drained and replaced one at a time on
   v1.35.2. Only the final check failed:
   OKE still listed the cycled-out node as `DELETED`. **Fix:** ignore
   `DELETED`/`DELETING` nodes when verifying.

Result: cluster on v1.35.2, no data lost, €0 spent. The image swap has run for
real; the `DELETED`-node fix will get its first real run at the next upgrade.

## Modes
Set the repo variable `AUTO_UPGRADE`:
- `true`  → **fully automatic**: check then upgrade, unattended.
- `false` → **check + notify only**: you run *OKE upgrade* manually from the Actions tab.

A manual run takes an optional `target` (e.g. `v1.36.4`), which runs even when
the check reports OK.

## Setup

### 1. CI identity (one-time, in the `oci-oke-infra` repo)
A dedicated least-privilege user + group + policy live in
`oci-oke-infra/terraform/modules/ci-upgrader`. Enable and apply **only that module**
(never touches the cluster):
```bash
# in oci-oke-infra/terraform, with enable_ci_upgrader=true, ci_domain_url and ci_user_email set:
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

The module's policy includes `use volumes`, which pre-upgrade backups need
(`volume-backups` alone isn't enough — creating a backup needs `VOLUME_WRITE`).
If your policy predates that statement, upgrade runs fail at the backup step,
before touching the cluster — run manually with `snapshot` unchecked to skip backups.

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
.github/workflows/check.yml    weekly check + issue alert + schedule keepalive
.github/workflows/upgrade.yml  manual or auto (workflow_run) upgrade
```

## Reuse
Parameterized entirely by repo variables — point `OCI_CLUSTER_ID` at any OKE
cluster (e.g. a second account) with its own scoped API key.
