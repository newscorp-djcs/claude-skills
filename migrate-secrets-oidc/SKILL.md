---
name: migrate-secrets-oidc
description: Migrate a CommonInstaller-based EC2 deploy project off plaintext/Terraform-resolved secrets and static Artifactory credentials onto runtime AWS Secrets Manager fetch plus OIDC-based Artifactory auth — across the deploy repo, its IAM repo (grants sts:GetWebIdentityToken), and dj-terraform-aws-artifactory-token-management (registers the role for RO access, now mandatory since the account-wide RO catch-all was removed). For ECS-based or build-only deploy components (no CommonInstaller/installer_config, no separate runtime IAM identity outside Jenkins), scope narrows to Jenkinsfile-only dj-shared credential cleanup — no IAM/Artifactory changes needed. This covers both credentials fed into dj-shared's `terraform()` step (backendConfig.username/password, backendConfig.token, docker.credential) and, for build-only/ECS Jenkinsfiles that don't call `terraform()` at all, any other `withCredentials`-bound Artifactory credential wrapping an arbitrary script block (curl, docker login, npm, etc.) — replaced with dj-shared's `withArtifactoryOidcCredentials` step. Exception: if the ECS task definition itself still resolves its Artifactory image-pull credential via a dynamic `data "aws_secretsmanager_secret"` lookup (fed into `credentials_param_arn`/`repositoryCredentials`), that still needs a deploy-repo Terraform edit (hardcode Platform Engineering's managed pull-secret ARN, move the image to `dj-docker-virtual`) and an IAM-repo grant on the ECS task *execution* role — a different, narrower mechanism than the EC2 OIDC/RO-registration pattern. Use when asked to "migrate this project to the new secrets pattern", "move off the static Artifactory key", "apply the secrets-manager-runtime-fetch pattern", "update IAM for the new CommonInstaller secrets/OIDC flow", "register a role for Artifactory RO/OIDC access", "clean up the Jenkinsfile credentials for this ECS project", "remove Artifactory credentials from this build-only project", or "move this ECS task off the static Artifactory pull secret to the managed pull secret".
---

# Migrate a deploy project to runtime Secrets Manager + OIDC Artifactory auth

Migrates a CommonInstaller-consuming Terraform deploy repo (the "stack" that builds EC2 user-data)
and its companion IAM repo from the old pattern — secret *values* resolved in Terraform and baked
into user-data/`AppConfig`, plus a static Artifactory API key — to the new pattern:

1. **Runtime Secrets Manager fetch** — addons that need a secret (New Relic license key, CrowdStrike
   CID, etc.) take a `secretId` (name or ARN) in their `AppConfig` entry. CommonInstaller's
   `Get-SecretManagerValue` resolves it at boot via the AWS CLI (auto-installed if missing). Terraform
   never sees the secret value — only its name/ARN.
2. **OIDC Artifactory auth** — Artifactory needs **no secret at all** anymore. CommonInstaller's
   `Get-ArtifactoryHeaders`/`Get-ArtifactoryToken` exchange the instance's own IAM identity
   (`aws sts get-web-identity-token --audience DJ-Artifactory-RO --signing-algorithm RS256`) for a
   short-lived JFrog access token, used as `Authorization: Bearer $TOKEN`. The only infrastructure
   requirement is an IAM permission to call `sts:GetWebIdentityToken`.

This is the pattern introduced in `MarketData/CommonInstaller` PR #195 (branch
`feature/secrets-manager-runtime-fetch`, Windows/PowerShell) and mirrored in
`Quest/LinuxCommonInstaller` PR #96 (branch `feature/secrets-manager-runtime-fetch`, Linux/bash) —
see `functions/shared-functions.ps1`/`functions/shared-functions.sh` in those repos for the canonical
implementation. This skill does **not** touch CommonInstaller/LinuxCommonInstaller itself; it adapts
a *consumer* of one of them (a deploy repo's Terraform) and that consumer's IAM role.

**There is a third place this touches, easy to forget:** granting `sts:GetWebIdentityToken` in the
IAM repo lets the role *call* STS, but since 2026-10-29 every AWS account's RO catch-all has been
removed from `newscorp-ghfb/dj-terraform-aws-artifactory-token-management` — a role that isn't
explicitly registered there gets a token-exchange error even with the IAM permission in place. Step
11 below registers the role as an `extra_ro_mappings` entry in that repo's
`accounts/iam-federation/prod/variables.tf`, once per account the deploy project actually runs in.

**There is a second, easy-to-miss layer**: the EC2 user-data that actually invokes
CommonInstaller/LinuxCommonInstaller is often rendered by a *shared* Terraform module (e.g.
`dj-terracycle`'s `ec2_instance`/`ec2_stack`), not by the deploy repo itself. That module's own
bootstrap template (`templates/linux_user_data.sh` / `templates/windows_user_data.ps1`) independently
downloads the installer zip *before* the installer ever runs, using its own Artifactory header built
from `installer_config.artifactory.accessKey` — completely separate from whatever OIDC logic lives
inside CommonInstaller itself. Removing `accessKey` from the deploy repo without checking this layer
first can break provisioning even though CommonInstaller's own code is already fully migrated. See
Step 0.

**There is a fourth place, also easy to miss, living in the Jenkinsfile rather than Terraform —
and it exists in *both* the deploy repo and the IAM repo, independently:** if a `Jenkinsfile` calls
`@Library('dj-shared')`'s `terraform()` step, older callers fetch a static Artifactory credential via
`withCredentials` and pass it into that step as `backendConfig.username`/`password`,
`backendConfig.token` (for a `type: "remote"` backend), or `docker.credential` (for pulling the
Terraform docker image itself). Once the pinned `dj-shared` ref is OIDC-aware (see
`Infrastructure/jenkins-pipeline-shared`'s `vars/terraform.groovy`), that step fetches its own
Artifactory OIDC token automatically for all three and now actively **rejects** these parameters —
each errors with "no longer supported" — so leaving the old `withCredentials`/`backendConfig`/`docker`
wiring in place isn't just redundant, it breaks the build once the library ref moves. The IAM repo
almost always has its own `Jenkinsfile` driving its own `terraform apply`, completely separate from
the deploy repo's — migrating the deploy repo's Jenkinsfile(s) and stopping there leaves the IAM
repo's build silently exposed to the same future breakage. See Step 4, item 6 (deploy repo) and Step
8, item 4 (IAM repo) — same patterns, same gating check, applied independently to each repo's own
Jenkinsfile(s).

For the deploy repo and the IAM repo, this skill stops short of pushing or opening PRs — it makes
local commits, shows you the diffs, and waits for your explicit go-ahead before `git push`/
`gh pr create` (Step 12, "Hand off for review"). The RO-registration repo
(`dj-terraform-aws-artifactory-token-management`, Step 11 below) is different: it's a narrow,
single-file, CI-reviewed change, so that step commits, pushes to a new branch, and opens the PR
directly — the PR review *is* the gate, there's no separate local-diff checkpoint for it.

---

## EC2 vs ECS/build-only — classify each deploy component before doing anything else

This skill's IAM-repo and RO-registration scope (Steps 7-11) only applies to **EC2-based** deploy
components. EC2 instances run CommonInstaller at boot, independently of Jenkins, so the instance's
own IAM role needs its own `sts:GetWebIdentityToken` grant and (if applicable) Secrets Manager
access. **ECS tasks and build-only pipelines have no such separate runtime identity** — the only
OIDC/Artifactory exchange for them happens inside the Jenkins pipeline itself (the `dj-shared`
`terraform()` step), which already has whatever permissions it needs there. So for ECS/build-only,
**skip the IAM repo and RO registration entirely** — the only thing that still applies is the
Jenkinsfile credential cleanup (Step 4, item 6).

A deploy repo's components typically live under `infrastructure/`, `stack/`, and `switch/` folders —
**classify each one independently**, since a single repo can mix types (e.g. `stack/` deploys an EC2
fleet while a sibling service in the same repo has since moved to ECS Fargate, or `switch/` only
flips Route53/ALB routing with no compute of its own either way). A "build-only" project — a CI
pipeline with no deploy-target Terraform of its own, just a Jenkinsfile that builds/publishes an
artifact — follows the same reduced scope as ECS.

```bash
for d in infrastructure stack switch; do
  [ -d "$d" ] || continue
  echo "=== $d ==="
  grep -l "installer_config\|ec2_instance\|ec2_stack\|ec2_cluster" "$d"/*.tf 2>/dev/null \
    && echo "  -> EC2-type: everything (Steps 0-11) applies"
  grep -l "ecs_service\|host_match_rule\|aws_ecs_service\|aws_ecs_task_definition" "$d"/*.tf 2>/dev/null \
    && echo "  -> ECS-type: Jenkinsfile-only (Step 4, item 6) — no IAM repo, no RO registration"
done
```

| Component type | Detection | What applies |
|---|---|---|
| **EC2** | `installer_config`/`addonPkg` present, or a module `source` referencing `dj-terracycle`'s `ec2_instance`/`ec2_stack`/`ec2_cluster` | Everything — Steps 0-11, as described below. |
| **ECS** (Fargate) | No `installer_config`; a module `source` referencing `dj-terracycle`'s `ecs_service`/`host_match_rule`, or raw `aws_ecs_service`/`aws_ecs_task_definition` resources | **Jenkinsfile-only.** Skip Steps 0-3, Step 4 items 1-5 and 7, Step 5, and Steps 7-11 entirely — there's no `installer_config` to migrate and no separate runtime IAM identity needing the OIDC/secrets grant (that's handled inside Jenkins already). Only **Step 4, item 6** (Jenkinsfile credential cleanup), then Step 6 (commit) and Step 12 (hand off) for the deploy repo alone. No IAM repo involvement at all. **Exception — see below** if the task definition's image pull also uses the old static-secret pattern. |
| **Build-only** (a CI pipeline with no deploy-target Terraform of its own) | No EC2/ECS Terraform at all; just a Jenkinsfile | Same as ECS — Jenkinsfile-only (Step 4, item 6), no IAM repo, no RO registration. |

**If a repo has both EC2 and ECS/build-only components:** run the full flow (Steps 0-11) only
against the EC2 component(s); run the Jenkinsfile-only flow against the ECS/build-only component(s)
independently. Don't let one component's classification apply repo-wide (finding `installer_config`
in `stack/` doesn't mean `switch/` needs Steps 0-3/7-11 too if `switch/` is actually ECS-based, or
vice versa). The one place this matters most is Step 11: an EC2 component in the same repo as an
ECS component still needs its own RO registration even though the ECS component doesn't. State which
components got which scope back to the user before editing anything, so they can correct the
classification if it's ambiguous (neither signal present, or both).

### Exception: an ECS component's own image pull still on the old static-secret pattern

The "Jenkinsfile-only, no IAM repo" rule above is about the **Terraform backend/Terraform-image**
credential the Jenkinsfile feeds into `dj-shared`'s `terraform()` step — a completely different
thing from how the **ECS task itself pulls its application's Docker image** from Artifactory. That
second mechanism has its own old/new pattern, independent of everything else in this skill:

- **Old pattern**: the ECS task definition's `credentials_param_arn` (or raw
  `repositoryCredentials.credentialsParameter`) is fed by a project-specific
  `data "aws_secretsmanager_secret"` data source (e.g. named `repo_secret`, looking up
  `"${var.env}/Artifactory/djsp"`), pointing at a static per-environment Artifactory credential, and
  the image reference uses a different registry path/port (e.g. `artifactory.dowjones.io:5001/...`).
- **New pattern**: the task definition points at Platform Engineering's **managed, shared, OIDC-refreshed
  pull secret** (cross-account, lives in PIB build) instead, and the image moves to the
  `dj-docker-virtual` registry path that secret is scoped to.

Detect it:
```bash
grep -rn 'aws_secretsmanager_secret\|credentials_param_arn\|repositoryCredentials' <terraform-dir>/*.tf
```

If this old pattern is present on an ECS component, **do Step 4, item 8 (deploy repo), and open the
IAM repo narrowly for Step 7's role-discovery plus Step 8, item 5 (IAM repo)**, in addition to (not
instead of) the Jenkinsfile-only cleanup in Step 4, item 6 — this is the one case where an ECS
component's deploy repo *and* its IAM repo both still need edits. The IAM-repo work here is narrow:
find the ECS task **execution** role (not the full Step 7 discovery for an EC2 project's own
`sts:GetWebIdentityToken` role/secrets grants — there's no such grant to find for ECS) and add only
the item-5 policy/attachment. Everything else that's skipped for ECS (Steps 0-3, 5, 9-11) stays
skipped; this exception adds exactly two items, nothing more.

---

## Inputs — ask for whatever isn't given or discoverable

Don't guess at any of these; ask the user if they aren't supplied or obvious from the repo:

| Input | How to resolve | Notes |
|---|---|---|
| Deploy repo path | Ask if not given | Local clone path, e.g. `../Dylan2011.WebHost.Deploy` |
| Terraform directory that builds `installer_config` | Search for a local containing `installer_config`/`addonPkg` (`grep -rl "installer_config" --include=*.tf`) | Don't assume a fixed name like `stack/<project>/` — some projects put it directly at the repo root (e.g. `factset/`) or elsewhere |
| Shared EC2 module + pinned ref, if any | Grep the Terraform directory for the module `source` line calling into it (e.g. `git@github.com:.../dj-terracycle.git//ec2_instance?ref=vX.Y.Z`) | Needed for Step 0 — skip only if the deploy repo truly owns its own user-data template with no shared module involved |
| IAM repo path | Ask — **default guess is `mktdata-iam`**, but confirm, don't assume | Different teams/projects may use a different IAM repo |
| IAM role resource name | Grep the IAM repo for the project name (e.g. `role-<project>-server.tf`) | If nothing matches, ask the user for the exact file/resource |
| Whether this deploy repo actually needs a *new* IAM role at all | Check `instance_profile_name` in the deploy repo's `ec2_stack`/`ec2_instance` module call against every other deploy repo migrated in the same session/sprint — two sibling deploy repos (e.g. an admin UI and its main app) commonly share one EC2 instance profile/role on purpose | If it matches a role already migrated, Steps 7-11 (IAM attachment + RO registration) are **already done** for this project — skip straight to the deploy-repo-only Terraform/Jenkinsfile work (Steps 1-6) and say so explicitly in the commit/PR, don't re-attach or re-register |
| Which secrets this project actually needs | Grep the deploy repo's `addonPkg`/locals for enabled addons (`NewRelicInfra`, `NewRelicDotNetAgent`, `CrowdStrikeSensor`, `datadog`, others) | Confirm the list with the user before editing — don't silently add secrets for disabled addons |
| Secrets Manager secret name per secret | Ask, offering known platform-standard names as defaults (e.g. New Relic license key is usually `MktData_NR_Platform_SS_License_Key`) | Never invent a secret name — always confirm |
| Base branch to branch off of | Ask if not obvious (usually `develop`) | |
| AWS account ID(s) the deploy project actually runs in | See the dedicated warning right below this table — do not resolve this from the first account-ID map you find by grepping the IAM repo | Getting this wrong means registering RO in a *live, real* account that has nothing to do with the project, while the account that actually needs it stays broken — both halves of the mistake ship silently, since `terraform apply` succeeds either way |
| The IAM role name needing RO | Same role migrated in Step 8 (e.g. `dylan-server`) — confirm it's the role the deployed EC2 instances actually assume, not an admin/sibling role in the same IAM repo | Grep the IAM repo for other `role-<project>-*.tf` files and ask if more than one plausibly needs RO |
| Local path to `dj-terraform-aws-artifactory-token-management` | Ask if not given, or search common dev roots for it | Needed for Step 11 |
| Jenkinsfile(s) in the deploy repo | `find <deploy-repo> -iname Jenkinsfile` — don't assume there's only one; they're typically under `infrastructure/`, `stack/`, and `switch/` folders | Needed for Step 4, item 6 — **every one found must be checked and cleaned up independently**, not just the first |
| Jenkinsfile(s) in the IAM repo | `find <iam-repo> -iname Jenkinsfile` — the IAM repo almost always has its own, driving its own `terraform apply`, entirely separate from the deploy repo's | Needed for Step 8, item 4 — same patterns as the deploy repo's Jenkinsfile(s), checked and cleaned up independently; easy to forget since the IAM repo migration is otherwise pure Terraform |
| The `dj-shared` library ref each Jenkinsfile pins, if any | Grep each Jenkinsfile found above (deploy repo *and* IAM repo) for `@Library('dj-shared`; if no explicit `@<ref>` is given, the org-wide default library config applies — ask the user whether that default is already OIDC-aware, don't assume | Gates whether it's safe to strip the old credentials in Step 4, item 6 and Step 8, item 4 — check per repo, a confirmed-OIDC-aware default for one repo applies to all since it's the same org-wide library, but re-verify if either repo pins its own explicit ref |

### Resolving the deploy account(s) — do not shortcut this

This has already gone wrong once in practice: a `dylan-server` RO registration was pushed, merged,
and only caught after the fact because the account IDs came from the *first* account-ID-shaped map
found by grepping the IAM repo (`shdsvc_account_id_by_env`), without checking what that map was
actually *for*. It turned out to build a cross-account ARN for an unrelated resource (a different
role's `AssumeRole` target *inside* the shared-services account) — not the account the migrated role
itself deploys into. The fix landed as a second, corrective PR.

**An IAM repo's `global`/root Terraform usually does not know its own deployment account at all** —
look for an `aws_assume_role_arn`-style variable defaulting to `null` and set by CI
credentials/parameters outside the repo (common in Jenkins-based DJ pipelines). If so, that repo
*cannot* tell you the account; look elsewhere. Do not treat a locals map as "the account mapping" just
because it is shaped like one — grep every place it's actually *referenced* (not just where it's
defined) and read what it's used for before trusting it.

The account almost always has to come from the **deploy repo** instead, because that's what Terraform
actually assumes a role into at apply time:

1. Check the deploy repo's own backend/provider/assume-role config for a direct account ID or ARN.
2. If it instead resolves a landing-zone name (e.g. `lz_account_name = "mktdata"` in a root
   `global.tfvars`, consumed by a shared `module "constants"` call), that landing-zone→account-ID
   mapping lives in the **shared module itself** (e.g. `dj-terracycle`'s `constants/main.tf`), not in
   either the deploy or IAM repo. Pull it from there — it's the authoritative source:
   ```bash
   gh api repos/<org>/<shared-module-repo>/contents/constants/main.tf?ref=<pinned-ref> \
     --jq '.content' | base64 -d | grep -n -A6 '<landing-zone-name> = {'
   ```
3. **State your reasoning and the resolved account IDs back to the user as a checkpoint before
   editing `dj-terraform-aws-artifactory-token-management`** — even if nothing in the inputs table
   above technically required asking. This is cheap insurance against exactly the mistake above,
   which would otherwise only surface after a live (wrong) change ships.
4. If no authoritative source can be found (no backend/provider account ID, no landing-zone
   registry, nothing), stop and ask the user directly for the account ID(s) rather than guessing
   from whatever account-shaped data happens to exist in either repo.

---

## Step 0 — Check the bootstrap-level Artifactory dependency, before touching accessKey

*(EC2-type components only — see "EC2 vs ECS/build-only" above. Skip entirely for an ECS/build-only
component — there's no EC2 user-data bootstrap template to check.)*

Before removing `installer_config.artifactory.accessKey` anywhere, find what actually renders this
project's EC2 user-data:

```bash
grep -rn 'source.*=.*"git@.*\(ec2_instance\|ec2_stack\|ec2_cluster\).*ref=' <terraform-dir>/*.tf
```

If a shared module is in play, locate its source (clone or find it locally — e.g. `dj-terracycle`),
check out the **exact pinned `ref`**, and inspect its `templates/linux_user_data.sh` /
`templates/windows_user_data.ps1`:

```bash
git show <ref>:<module-path>/templates/linux_user_data.sh   | grep -n "accessKey\|artifactoryHeader"
git show <ref>:<module-path>/variables.tf                   | grep -n -A4 'variable "installer_config"'
```

**For `dj-terracycle` specifically: the fix is already released as of `v0.21.0`.** Its
`ec2_instance`/`ec2_stack` modules dropped the mandatory `installer_config.artifactory.accessKey`
validation and do the OIDC token exchange directly in both bootstrap templates from that tag
forward (verified: `v0.20.0` through `v0.20.3` all still require `accessKey`; `v0.21.0` does not).
The PR that did this (#234) was closed without merging — don't link to it or treat "merged"/"open"
PR state as the signal; **check the actual tag content**, not PR history:

```bash
gh api repos/newscorp-ghfb/dj-terracycle/contents/ec2_stack/variables.tf?ref=v0.21.0 \
  --jq '.content' | base64 -d | grep -n -A4 'variable "installer_config"'   # should show no validation block
```

If the deploy project is pinned below `v0.21.0`, **bump the `ref=` on every `dj-terracycle` module
call in the deploy repo's Terraform to `v0.21.0` or a later tag** (not a branch — this fix is tagged
and released, so there's no reason to pin a branch for it) as part of Step 4, before removing
`accessKey`. Confirm with the user only if bumping the version could plausibly affect other behavior
they care about (check the tag's other changes between the pinned version and `v0.21.0`); otherwise
this is a mechanical prerequisite, not a judgment call.

For any *other* shared module (not `dj-terracycle`, or a future `dj-terracycle` regression before a
fix is tagged) where the template still depends on `accessKey`, **before asking the user how to
proceed, check whether a fix already exists upstream** in that module's own repo:

```bash
cd <shared-module-repo>
gh pr list --state all --search "oidc artifactory accessKey" --limit 10
```

If a PR (open or merged) already migrates that module's bootstrap templates to OIDC, surface it by
number/URL as a candidate ref to bump to — don't make the user discover it themselves, and don't assume
it's merged just because it exists; check its state and whether it's actually been released/tagged yet.

| Finding | Action |
|---|---|
| `dj-terracycle`, pinned below `v0.21.0` | Bump `ref=` to `v0.21.0` or later (a tagged release, not a branch) as part of Step 4 — this is the released fix, mechanical unless the version jump has other side effects worth flagging (see above). |
| `dj-terracycle`, already pinned at `v0.21.0` or later | Already fixed — safe to proceed, remove `accessKey` from the deploy repo in Step 4 as normal. |
| Any other shared module: template builds its own header from `.artifactory.accessKey`, and/or `variables.tf` has a validation requiring it non-blank, **and no existing fix PR was found** | **Do not remove `accessKey` from the deploy repo yet.** The shared module needs to be migrated to OIDC first (same pattern as CommonInstaller itself — inline `aws sts get-web-identity-token` + JFrog token exchange in both templates, then drop the `variables.tf` validation). Flag this to the user as a separate, higher-blast-radius change (the module likely has many consumers) and ask how they want to proceed — fixing the module and bumping this project's `ref=` to the fixed version, or leaving `accessKey` in place here as an interim shim until the module is fixed. Don't silently pick one. |
| Same, but **an existing fix PR/branch was found upstream** | Tell the user about it (number, URL, merged/open/unreleased state) and offer it as a third option alongside "fix it yourself" / "interim shim" — e.g. bump this project's `ref=` to that branch/tag once it's available, or point `installer_branch`-style overrides at it for early testing if it's still unmerged. Still don't pick for them. Don't assume a closed/unmerged PR means no fix shipped — check whether a later tag absorbed the same change under a different PR, the way `dj-terracycle` v0.21.0 did after PR #234 was closed. |
| Template already does the OIDC exchange itself (no `accessKey` reference) | Safe to proceed — remove `accessKey` from the deploy repo in Step 4 as normal. |
| No shared module — the deploy repo owns its own user-data template directly | Check that template the same way; migrate it in place if it still uses `accessKey`. |

This step exists because CommonInstaller's own OIDC migration only covers what runs *after* the
installer zip is already downloaded. The *initial* fetch of that zip is commonly built by a separate,
shared module's template, which has its own independent Artifactory auth and does not get fixed just
because CommonInstaller was fixed.

---

## Step 1 — Discover current state in the deploy repo

```bash
cd <deploy-repo>
git status                       # make sure there's nothing uncommitted to stash/lose
git fetch origin
git log --oneline origin/develop -1   # confirm what "latest develop" is before pulling

# find the Terraform directory that builds installer_config — don't assume it's named stack/<project>/
grep -rl "installer_config" --include=*.tf .

# existing old-pattern indicators
grep -rn "aws_secretsmanager_secret" <terraform-dir>/*.tf
grep -rn "accessKey\|accessKeyType\|artifactory_secret_name\|X-JFrog-Art-Api" <terraform-dir>/*.tf <terraform-dir>/*.tfvars
grep -rn "addonPkg\|NewRelicInfra\|NewRelicDotNetAgent\|CrowdStrikeSensor" <terraform-dir>/*.tf
grep -rn "secretId" <terraform-dir>/*.tf   # already-migrated indicator

# installer_config.installer.version wildcard — check it's pinned to the current major-version
# baseline for whichever installer "entry" this project uses (PowerShell vs Linux have different
# baselines), not a stale one (see Step 4, item 7)
grep -n -A3 "installer = {" <terraform-dir>/*.tf

# Jenkinsfile-level: dj-shared's terraform() step and its backend/docker credential wiring.
# Expect more than one (commonly under infrastructure/, stack/, switch/) - check each independently.
find . -iname Jenkinsfile
for f in $(find . -iname Jenkinsfile); do
  echo "=== $f ==="
  grep -n "@Library('dj-shared" "$f"
  grep -n "withCredentials\|artifactory_terraform_backend\|backendConfig\|credential:" "$f"
  # Pattern D candidates: an Artifactory credential bound via withCredentials for something
  # other than dj-shared's terraform() step (common in build-only Jenkinsfiles that never call
  # terraform() at all) — see Step 4, item 6, Pattern D
  grep -n -i "credentialsId.*artifactory\|artifactory.*credentialsId" "$f"
done

# ECS image-pull secret old pattern (see Step 4, item 8) — independent of everything above,
# only relevant if this component is ECS-type (aws_ecs_task_definition / credentials_param_arn present)
grep -rn "credentials_param_arn\|repositoryCredentials" --include=*.tf .
```

Report what you find before changing anything. If `secretId` usage already covers every secret-needing
addon and no `accessKey`/`artifactory_secret_name`/old `aws_secretsmanager_secret_version` pattern
remains, this repo is already migrated — stop and report that.

If uncommitted changes exist, stash (`git stash -u`) or ask the user how to handle them before pulling
latest develop — never discard work silently.

---

## Step 2 — Confirm secrets and naming with the user

*(EC2-type components only — see "EC2 vs ECS/build-only" above. Skip entirely for an ECS/build-only
component.)*

For every addon found **enabled** that needs a secret, ask for (or confirm) the Secrets Manager
secret name/alias to use. Use `AskUserQuestion` rather than guessing. Known platform-standard example:

- New Relic license key → commonly `MktData_NR_Platform_SS_License_Key`
- CrowdStrike CID, and anything else → no platform-wide standard is known to this skill; always ask

Confirm Artifactory is in play (it almost always is) — no secret name is needed for it, just note that
the IAM step will need to grant `sts:GetWebIdentityToken`.

**For every secret, also check what KMS key actually encrypts it — don't assume the default
`aws/secretsmanager` key.** Some accounts have a long-lived secret (created years before this
migration, often by hand) that's encrypted with a customer-managed key instead:

```bash
aws secretsmanager describe-secret --secret-id <secret-name> --region <region> | grep KmsKeyId
```

If `KmsKeyId` is a key ID/ARN rather than absent or `alias/aws/secretsmanager`, resolve it to an
alias name (`aws kms list-aliases --region <region>`, matching `TargetKeyId`) — you'll need that
alias in Step 8 if the IAM repo's shared-policy module for this secret has a KMS-decrypt statement
gated by its own alias variable (see Step 8, item 3a). **Watch for account-specific naming quirks**:
an alias can itself contain a literal `alias/` in its name (e.g. the real alias is
`alias/alias/newrelic`, not `alias/newrelic`) if whoever created it passed an already-prefixed name
to the alias-creation call. Use whatever `list-aliases` actually returns, not what you'd expect it
to be named.

Wait for answers before editing files.

---

## Step 3 — Branch the deploy repo

```bash
git checkout -b feature/secrets-manager-oidc-migration origin/develop
```

(Pick a different branch name if the user prefers one, or if this name is already taken.)

---

## Step 4 — Edit the deploy repo Terraform

**For an ECS/build-only component (see "EC2 vs ECS/build-only" above), skip straight to item 6
below** — items 1-5
and 7 only apply to EC2-type components, since there's no `installer_config` on an ECS component to
edit in the first place. **If that ECS component's image pull is also still on the old static-secret
pattern (see the "Exception" callout above), also do item 8 below.**

In the Terraform directory found in Step 1 (e.g. `stack/<project>/`, `factset/`, or wherever
`installer_config` actually lives):

1. **Remove secret-VALUE data sources** — `data "aws_secretsmanager_secret"` /
   `data "aws_secretsmanager_secret_version"` blocks that were only used to pull a secret's value into
   Terraform state for baking into user-data. **Before removing, grep the whole repo** for other
   references to that data source's local name — if it's used anywhere else, flag it to the user and
   ask before removing. If the file that held these becomes empty, leave it as an empty file rather
   than `git rm` it (deleting a tracked file is treated as a destructive op) — note this to the user,
   who can decide to actually delete it later.

2. **Remove Artifactory secret plumbing** — any `accessKey`, `accessKeyType`, or
   `artifactory_secret_name` variable/local/tfvars entry. Artifactory needs zero stored config now.

3. **Add `secretId` to each addon that needs one**, in the `installer_config`/`addonPkg` locals, e.g.:
   ```hcl
   {
     name     = "NewRelicInfra"
     enabled  = true
     secretId = var.newrelic_license_secret_name
   }
   ```

4. **Add a variable per secret** in `variables.tf`, defaulted to the name confirmed in Step 2:
   ```hcl
   variable "newrelic_license_secret_name" {
     type    = string
     default = "MktData_NR_Platform_SS_License_Key"
   }
   ```
   Remove any now-unused variable (e.g. `artifactory_secret_name`) and its references across all
   `*.tfvars` files (nonprod/stag/prod) — secret names should usually be account-agnostic friendly
   names, so one variable default typically covers every environment; only split per-environment if
   the user says the name actually differs per account.

5. **If CommonInstaller's new pattern hasn't merged/published yet**, offer to add a temporary
   `installer_branch` override (clearly marked `# TEMPORARY`) in the nonprod tfvars pointing at the
   CommonInstaller feature branch, so the change can be tested before CommonInstaller's PR merges.
   Ask the user whether this is needed and what branch to pin.

6. **Check whether the Jenkinsfile itself still wires a static Artifactory credential into
   `dj-shared`'s `terraform()` step**, and clean it up if the pinned library ref supports OIDC.

   **Do this for every Jenkinsfile found in the repo, not just the first one you find.** A deploy
   repo commonly has more than one — typically under `infrastructure/`, `stack/`, and `switch/`
   folders (e.g. `infrastructure/Jenkinsfile`, `stack/Jenkinsfile`, `switch/Jenkinsfile`) — and each
   can independently carry its own `withCredentials`/`backendConfig`/`docker` wiring (or none at
   all). Fixing only the one you happened to open first leaves the others silently broken the next
   time the `dj-shared` ref moves. Re-run the gating check and the pattern search below
   per-Jenkinsfile; don't assume the result from one applies to the others.

   First confirm the gating condition for that Jenkinsfile — **don't skip this check**, since older `dj-shared` refs still
   require these parameters and removing them while pinned to one breaks the build outright (no
   credentials at all would be supplied where the old code path expected them):
   ```bash
   gh api -H "Accept: application/vnd.github+json" \
     "https://github.dowjones.net/api/v3/repos/Infrastructure/jenkins-pipeline-shared/contents/vars/terraform.groovy?ref=<pinned-ref-or-default-branch>" \
     --jq '.content' | base64 -d | grep -n "no longer supported"
   ```
   If this prints all three — `backendConfig.username`/`password`, `backendConfig.token`, and
   `docker.credential` — the ref is OIDC-aware and it's safe to proceed with Patterns A-C below. If it
   prints nothing (or only some), the pinned ref doesn't fully support OIDC yet — **do not touch the
   Jenkinsfile**; flag this to the user the same way Step 0 flags an unfixed `dj-terracycle` ref, and
   ask whether to bump the `@Library('dj-shared@...')` ref as a prerequisite or leave the Jenkinsfile
   as an interim shim until that library's OIDC migration ships more broadly.

   **Pattern D has its own, separate gating check** — it's a different step (`withArtifactoryOidcCredentials`),
   added to `dj-shared` after Patterns A-C's `terraform()` changes, so a ref can be OIDC-aware for A-C
   and still lack it:
   ```bash
   gh api -H "Accept: application/vnd.github+json" \
     "https://github.dowjones.net/api/v3/repos/Infrastructure/jenkins-pipeline-shared/contents/vars/withArtifactoryOidcCredentials.groovy?ref=<pinned-ref-or-default-branch>" \
     --jq '.content' 2>/dev/null
   ```
   A 404 (empty output / `gh api` error) means the pinned ref doesn't have this step yet — leave any
   Pattern D candidate's `withCredentials` wiring in place and flag it the same way, rather than
   applying Pattern D below.

   Once confirmed OIDC-aware for the pattern(s) present, up to four independent patterns may be
   present — remove whichever apply (a single Jenkinsfile can have more than one, unlike the
   deploy/IAM-repo migration where the old patterns are mutually exclusive):

   **Pattern A — `backendConfig.username`/`password`** (e.g. `Dylan2011.WebHost.Deploy/stack/Jenkinsfile`,
   `mktdata-iam/Jenkinsfile`):
   ```groovy
   // before
   withCredentials([usernamePassword(credentialsId: 'artifactory_terraform_backend', usernameVariable: 'artifactory_user', passwordVariable: 'artifactory_pass')]) {
     ...
     terraform(
       ...
       backendConfig: [
         subpath: "${subpath}",
         username: "${artifactory_user}",
         password: "${artifactory_pass}"
       ],
       ...
     )
   }
   ```
   ```groovy
   // after
   ...
   terraform(
     ...
     backendConfig: [
       subpath: "${subpath}"
     ],
     ...
   )
   ```

   **Pattern B — `backendConfig.token`, on a `type: "remote"` backend** (e.g.
   `MarketDataSDL.Deploy/stack/Jenkinsfile`):
   ```groovy
   // before
   withCredentials([string(credentialsId: 'artifactory_terraform_backend_token', variable: 'artifactory_token')]) {
     ...
     terraform(
       ...
       backendConfig: [
         type: "remote",
         token: "${artifactory_token}",
         organization: "...",
         workspace: [ name: "..." ]
       ],
       ...
     )
   }
   ```
   ```groovy
   // after
   ...
   terraform(
     ...
     backendConfig: [
       type: "remote",
       organization: "...",
       workspace: [ name: "..." ]
     ],
     ...
   )
   ```

   **Pattern C — `docker.credential`, for pulling the Terraform docker image itself** (independent of
   which backend pattern, A or B, is also present — e.g. also seen in
   `MarketDataSDL.Deploy/stack/Jenkinsfile`, where it's what actually fails *first*, since the
   `terraform()` step validates its `docker:` map before its `backendConfig:` map):
   ```groovy
   // before
   terraform(
     docker: [
       image: 'hashicorp/terraform',
       registry: 'https://artifactory.dowjones.io:5001',
       credential: 'artifactory_djsp_ro'
     ],
     ...
   )
   ```
   ```groovy
   // after
   terraform(
     docker: [
       image: 'hashicorp/terraform',
       registry: 'https://artifactory.dowjones.io:5001'
     ],
     ...
   )
   ```
   Don't confuse this with an unrelated `docker.withRegistry(...)`/`docker.image(...).inside(...)` call
   elsewhere in the same Jenkinsfile that pulls an *application* image (not the Terraform image) using
   a Jenkins credential — that's a separate, legitimate use of Docker Pipeline's own registry auth and
   is out of scope for this migration.

   **Pattern D — an Artifactory credential bound via `withCredentials` for something other than
   `dj-shared`'s `terraform()` step** (e.g. a plain `sh` step doing `curl`, `docker login`, `npm`
   publish/install, or any other direct Artifactory call). This is the **only** Jenkinsfile pattern
   that applies to most build-only projects, since a build-only Jenkinsfile commonly never calls
   `terraform()` at all — don't conclude "nothing to migrate here" just because Patterns A-C don't
   match; check for this one independently, in every `stage`, not just near any `terraform(...)` call:
   ```groovy
   // before
   withCredentials([usernamePassword(credentialsId: 'artifactory_djsp_ro', usernameVariable: 'ARTIFACTORY_USR', passwordVariable: 'ARTIFACTORY_PSW')]) {
     sh 'curl -u $ARTIFACTORY_USR:$ARTIFACTORY_PSW https://artifactory.dowjones.io/artifactory/api/search/pattern?pattern=...'
   }
   ```
   ```groovy
   // after
   withArtifactoryOidcCredentials(scope: 'ro') {
     sh 'curl -u $ARTIFACTORY_USR:$ARTIFACTORY_PSW https://artifactory.dowjones.io/artifactory/api/search/pattern?pattern=...'
   }
   ```
   Key points, distinct from Patterns A-C:
   - **Preserve the body untouched — only swap the wrapper.** `withArtifactoryOidcCredentials` takes
     optional `usernameVariable`/`passwordVariable` parameters (defaulting to `ARTIFACTORY_USR`/
     `ARTIFACTORY_PSW`) specifically so the script body inside the block needs zero edits: pass
     whatever variable names the old `usernamePassword(...)` binding used, e.g.
     `withArtifactoryOidcCredentials(usernameVariable: 'ART_USER', passwordVariable: 'ART_PASS')` if
     the old binding didn't use the default names.
   - **Scope selection (`ro` vs `rw`) is a judgment call — don't guess silently.** A credential ID or
     usage that's clearly read-only (searching/downloading, e.g. `artifactory_djsp_ro`) maps to
     `scope: 'ro'`; one that's clearly publishing/uploading (e.g. a credential ID containing `rw`,
     `publish`, or `push`, or a script block doing `curl -X PUT`/`npm publish`) maps to `scope: 'rw'`.
     If it's ambiguous from the credential ID and the script body alone, ask the user rather than
     defaulting to one.
   - **A single-value `string(...)` binding is not a 1:1 replacement** — if the old binding was
     `string(credentialsId: '...', variable: 'ARTIFACTORY_TOKEN')` (a bare API-key/token var, not a
     username+password pair) and the script body uses it as a single bearer-style value (e.g.
     `-H "X-JFrog-Art-Api: $ARTIFACTORY_TOKEN"` or `-H "Authorization: Bearer $ARTIFACTORY_TOKEN"`),
     `withArtifactoryOidcCredentials` still only produces a username+password pair — point the script
     at the password variable as the bearer token (e.g. pass `passwordVariable: 'ARTIFACTORY_TOKEN'`
     and leave the body's `Bearer $ARTIFACTORY_TOKEN` usage as-is) rather than silently assuming Basic
     auth is fine to introduce in its place; confirm with the user if the body does anything with the
     username side that doesn't translate (e.g. an `X-JFrog-Art-Api` header, which has no OIDC
     equivalent at all — that header-based API-key scheme is gone entirely under OIDC, so a script
     that specifically needs it has no direct replacement and must switch to Bearer-token or Basic
     auth instead, which may require a change beyond this skill's Jenkinsfile-only scope).
   - **Not exclusive to build-only/ECS** — an EC2-type repo's Jenkinsfile can independently have this
     pattern too (e.g. a `stage` that curls Artifactory for something unrelated to the `terraform()`
     call elsewhere in the same file). Check for it in every repo type, not just build-only/ECS ones.

7. **Check `installer_config.installer.version` is pinned to the current major-version wildcard for
   whichever installer this project actually uses, not a stale one.** There are two unrelated
   installers with two unrelated version lines — **check `installer_config.installer.entry` first**
   to know which baseline applies:
   ```hcl
   installer = {
     entry   = "CommonInstaller-aws.ps1"   # Windows/PowerShell -- MarketData/CommonInstaller
     # entry = "CommonInstaller.sh"        # Linux/bash         -- Quest/LinuxCommonInstaller
     version = "2.1.*"        # <- stale, check this
     branch  = var.commonInstaller
   }
   ```

   | `entry` | Installer | Current baseline | Re-derive from |
   |---|---|---|---|
   | `CommonInstaller-aws.ps1` | `MarketData/CommonInstaller` (PowerShell) | `"3.0.*"` | `$version` in its `build.ps1` on `develop` |
   | `CommonInstaller.sh` | `Quest/LinuxCommonInstaller` (bash) | `"3.1.*"` | `major_version` in its `Jenkinsfile.build` on `develop` |

   This field is a wildcard matcher resolved against packages the installer's own build script
   publishes to Artifactory (e.g. PowerShell's `build.ps1` sets `$version` feeding
   `CommonInstaller-$version.$Build.zip`; Linux's `Jenkinsfile.build` sets `major_version` feeding
   `${publishProject}-${major_version}.${env.BUILD_NUMBER}.zip`). If a deploy repo is still pinned to
   an older major-version wildcard than what its installer currently publishes, **no package matches
   and the install fails to resolve an installer artifact at boot** — this is a hard break, not just
   staleness. Bump to the baseline for whichever `entry` this project uses:
   ```hcl
     version = "3.0.*"   # CommonInstaller-aws.ps1
     # version = "3.1.*" # CommonInstaller.sh
   ```
   **If the project's current value is already at or above its installer's baseline (e.g. already
   `"3.1.*"` or `"3.2.*"` for a Linux project), leave it as-is** — don't downgrade a newer pin to match
   this baseline, and don't treat a higher value as evidence of a typo. Check and bump this even for a
   project where every other Step 1 indicator already shows the secrets-manager pattern in place — the
   version wildcard is independent of that and can still be stale on its own. To re-derive the current
   baseline in the future (each installer's own baseline goes stale independently as that installer
   bumps its major version again):
   Both repos live on the Enterprise host (`github.dowjones.net`), not `github.com` — set `GH_HOST`
   or these 404:
   ```bash
   # PowerShell (MarketData/CommonInstaller)
   GH_HOST=github.dowjones.net gh api repos/MarketData/CommonInstaller/contents/build.ps1?ref=develop --jq '.content' | base64 -d | grep '^\$version'
   # Linux (Quest/LinuxCommonInstaller)
   GH_HOST=github.dowjones.net gh api repos/Quest/LinuxCommonInstaller/contents/Jenkinsfile.build?ref=develop --jq '.content' | base64 -d | grep 'major_version'
   ```

8. **ECS components only — migrate the image-pull secret off the old dynamic Secrets Manager lookup
   onto Platform Engineering's managed, OIDC-refreshed pull secret.** This applies when the task
   definition's `credentials_param_arn`/`repositoryCredentials.credentialsParameter` is fed by a
   project-specific `data "aws_secretsmanager_secret"` lookup rather than the shared cross-account
   secret (see the "Exception" callout under "EC2 vs ECS/build-only" above for how to detect this).
   It's unrelated to the OIDC/`sts:GetWebIdentityToken` pattern used elsewhere in this skill — ECS
   pulls the image *before* the task's own code runs, so it can't do a runtime token exchange itself;
   instead it reads a secret Platform Engineering keeps refreshed on its behalf. The authoritative
   current values live in "ECS / Fargate image pulls (managed pull secret)" in
   `dj-terraform-aws-artifactory-token-management`'s `iam-oidc-artifactory-token-consumer-guide.md` —
   re-check that doc rather than trusting the values below if they look stale (the secret's ARN
   suffix only changes if it's ever recreated, at which point that guide is updated).

   a. **Remove the dynamic lookup** (commonly in `data.tf`):
   ```hcl
   # before
   data "aws_secretsmanager_secret" "repo_secret" {
     name = "${var.env}/Artifactory/djsp"
   }
   ```
   Before removing, grep the whole repo for other references to that data source's local name (same
   rule as item 1 above) — if it's used anywhere else, flag it and ask first.

   b. **Add the managed secret's ARN as a local** (in `main.tf`, next to the ECS service/task
   definition locals), and point the task definition's credential param at it:
   ```hcl
   # Platform Engineering's managed Artifactory pull secret (OIDC-refreshed, read-only on
   # dj-docker-virtual). Must be the full ARN including the suffix for cross-account
   # repositoryCredentials — see the consumer guide if this looks stale.
   artifactory_pull_secret_arn = "arn:aws:secretsmanager:us-east-1:775258986048:secret:djin-prod-artifactory-ecs-docker-ro-NoaPmf"
   ```
   ```hcl
   # before
   credentials_param_arn = data.aws_secretsmanager_secret.repo_secret.arn
   # after
   credentials_param_arn = local.artifactory_pull_secret_arn
   ```

   c. **Move the image reference onto the `dj-docker-virtual` path** the managed secret is scoped to
   (READ-only) — the old static-credential image path commonly used a different registry
   subpath/port:
   ```hcl
   # before
   image = "artifactory.dowjones.io:5001/${local.image}"
   # after
   image = "artifactory.dowjones.io/dj-docker-virtual/${local.image}"
   ```
   If the existing image path doesn't look like this shape (e.g. it's already a different named
   virtual repo), confirm with the user rather than assuming the `:5001` → `dj-docker-virtual`
   rewrite applies as-is.

   d. **This has a hard IAM-repo dependency** — the ECS task **execution** role (not the task role)
   needs read access to the managed secret and its KMS key, or image pulls fail at task start/scale-out.
   See Step 8, item 5. Don't let the deploy-repo PR merge/apply ahead of the IAM-repo one.

   Back to item 6's Jenkinsfile patterns: in every pattern found there, remove only the specific credential-binding entry (the `usernamePassword(...)`
   or `string(...)` list item) that supplies the Artifactory credential — if the same
   `withCredentials([...])` call also binds other, unrelated credentials used elsewhere in the block
   (e.g. an Apollo key, an SSH key), leave those bindings alone and only unwrap/remove the whole
   `withCredentials` step if its binding list becomes empty. Note the now-unused Jenkins credential ID
   (e.g. `artifactory_terraform_backend`, `artifactory_terraform_backend_token`, `artifactory_djsp_ro`)
   to the user as a candidate for cleanup in the Jenkins credential store — deleting a Jenkins
   credential is outside this skill's reach.

   **After unwrapping, verify the file's `{`/`}` count still balances before moving on** —
   `grep -o "{" <file> | wc -l` vs `grep -o "}" <file> | wc -l`. Removing a `withCredentials([...]) {
   ... }` wrapper removes one `{` (the wrapper's own) and, depending on exactly how the old/new
   block boundaries were drawn, can leave the wrapper's matching closing `}` behind as an orphan
   right after the `terraform(...)` call's closing `)`. This has actually happened in practice
   (twice, in two sibling Jenkinsfiles in the same repo, both using the identical boilerplate) —
   the stray `}` is easy to miss by eye since it looks like it could belong to the enclosing
   `stage(...)` block instead. A brace-count mismatch means there's an orphaned (or missing) `}`
   somewhere in the file; find it by re-reading the specific region you just edited, not by
   scanning the whole file.

---

## Step 5 — Validate the deploy repo changes

*(EC2-type components only — see "EC2 vs ECS/build-only" above. For an ECS/build-only component,
there's nothing from items 1-5/7 to validate here; the brace-balance check in Step 4, item 6 already
covers the Jenkinsfile edit.)*

```bash
terraform fmt -check -diff <terraform-dir>/
grep -rn "accessKey\|accessKeyType\|artifactory_secret_name\|X-JFrog-Art-Api" <terraform-dir>/   # should be empty
```

`terraform validate` may fail in a sandboxed environment without SSH access to a private module
source (e.g. `dj-terracycle`) — treat that as expected/non-blocking, note it to the user, and rely on
`terraform fmt -check` instead.

---

## Step 6 — Commit the deploy repo (do not push yet)

Stage only the files actually changed and commit with a message describing the migration. Do not push.

---

## Step 7 — Discover and confirm the IAM repo + role

*(EC2-type components only — see "EC2 vs ECS/build-only" above. Skip Steps 7-11 entirely for an
ECS/build-only component; don't open or touch an IAM repo for it at all — the Jenkins pipeline
already has whatever OIDC/secrets permissions it needs, independent of any project-specific IAM
role. **Exception:** if the ECS component's image pull is still on the old static-secret pattern
(see the "Exception" callout under "EC2 vs ECS/build-only"), open the IAM repo narrowly to find the
ECS task **execution** role for Step 8, item 5 — nothing else in Steps 7-11 applies, there's no
`sts:GetWebIdentityToken`/secrets grant or RO registration involved in this exception.)*

```bash
cd <iam-repo>            # ask for this path if not given; default guess is mktdata-iam — confirm, don't assume
git status
git fetch origin
git checkout -b feature/secrets-manager-oidc-migration origin/develop

grep -rln "role-.*server" global/   # or wherever role files live in this repo
grep -rln "<project-name>" global/  # find the specific role for this project

# Jenkinsfile-level: same dj-shared terraform() credential wiring as the deploy repo (Step 4, item
# 6) can independently exist here too — the IAM repo almost always runs its own terraform apply.
find . -iname Jenkinsfile
for f in $(find . -iname Jenkinsfile); do
  echo "=== $f ==="
  grep -n "@Library('dj-shared" "$f"
  grep -n "withCredentials\|artifactory_terraform_backend\|backendConfig\|credential:" "$f"
done
```

If no matching role file is found, ask the user for the exact file and resource name — don't guess at
IAM repo layout, it varies.

For each secret confirmed in Step 2, check whether a shared IAM policy already exists scoped to that
secret name (e.g. `policy-newrelic-shared.tf`) and whether the role is already attached to it. If a
secret has **no existing shared policy**, stop and ask the user whether to create one, attach a
different existing policy, or scope a new statement inline — do not invent new Secrets Manager IAM
grants unprompted.

---

## Step 8 — Edit the IAM repo

*(Items 1-4: EC2-type components only — see "EC2 vs ECS/build-only" above. Skip entirely for an
ECS/build-only component. Item 5 is the exception: an ECS component whose image pull is still on the
old static-secret pattern needs item 5 only — none of items 1-4.)*

1. **Remove the Artifactory-specific secrets policy attachment** on the role, if one exists — it's
   now dead weight since Artifactory auth no longer reads from Secrets Manager. Don't touch the
   underlying shared policy resource itself (e.g. `artifactory_shared_policy`) if other,
   not-yet-migrated roles still attach to it — check with
   `grep -rn "aws_iam_policy\.<name>\.\*\.arn" <iam-repo>/global/*.tf` before assuming it's safe to
   remove or repurpose.

2. **Grant the OIDC token exchange via a shared policy, not an inline statement.** Check whether a
   shared policy for this already exists in the IAM repo (e.g. `grep -rln "GetWebIdentityToken"
   <iam-repo>/global/*.tf`). If one exists, just attach the role to it (skip to step 3). If not,
   create one following the repo's existing shared-policy convention (see
   `policy-newrelic-shared.tf` for the pattern to copy):
   ```hcl
   # policy-artifactory-oidc-shared.tf
   data "aws_iam_policy_document" "artifactory_oidc_iam_document" {
     statement {
       sid       = "ArtifactoryOidcTokenExchange"
       effect    = "Allow"
       actions   = ["sts:GetWebIdentityToken"]
       resources = ["*"]
     }
   }

   resource "aws_iam_policy" "artifactory_oidc_shared_policy" {
     count       = var.region_id == "us-east-1" ? 1 : 0
     name        = "mktdata_artifactory_oidc"
     description = "Policy to grant sts:GetWebIdentityToken for OIDC-based Artifactory auth"
     policy      = data.aws_iam_policy_document.artifactory_oidc_iam_document.json
   }
   ```
   Then attach the role to it the same way other shared policies are attached in this repo (one
   `aws_iam_role_policy_attachment` per role — most of these repos deliberately avoid
   `aws_iam_policy_attachment`'s `roles = [...]` list form; check for a comment explaining why
   before using it):
   ```hcl
   resource "aws_iam_role_policy_attachment" "<role>_artifactory_oidc_iam_attachment" {
     count      = local.nonprod_stag_prod ? 1 : 0
     role       = aws_iam_role.<role>[0].id
     policy_arn = element(concat(aws_iam_policy.artifactory_oidc_shared_policy.*.arn, [""]), 0)
   }
   ```
   Don't invent a different policy name/shape if the repo already has one for this — reuse it.

3. **Ensure the role is attached** to the shared policy for every secret confirmed in Step 2 (e.g.
   `newrelic_shared_policy`). Add the attachment if missing; leave existing attachments alone if
   already correct.

   3a. **If the shared-policy module is `count`-gated on a secret-name variable (e.g.
   `newrelic_shared_policy`'s `count = ... (var.newrelic_secret_name != "" ? 1 : 0)`), check whether
   it also has a companion KMS-alias variable** (e.g. `newrelic_secret_kms_alias`) feeding a
   `kms:Decrypt`/`kms:DescribeKey` statement — `grep -n "kms_alias\|kms:Decrypt" <module-dir>/*.tf`.
   If so, **setting the secret-name variable alone is not enough**: the KMS statement's `resources`
   is typically built as `var.<kms_alias_var> != "" ? "arn:...:alias/${var.<kms_alias_var>}" : ""`,
   so leaving the alias var unset/default-empty puts a bare empty string in the policy document.
   Terraform's plan/validate won't catch this — it only fails at `apply`, against the real AWS API,
   with `Error: creating IAM Policy (...): MalformedPolicyDocument: Resource  must be in ARN format
   or "*".` (note the double space — that's the empty string rendered inline). This has happened in
   practice: activating `newrelic_shared_policy` in `ibd-iam` by setting only `newrelic_secret_name`
   broke a real prod apply (`job/ibd/prod/admin/iam`) because `IBD_NR_License_Key` is encrypted with
   a customer-managed key, not the default one. Use the KMS lookup from Step 2 to set the alias
   variable at the same time you set the secret-name variable — never one without the other.

   3b. **Even with the alias variable correctly set, check how the KMS statement's `resources` is
   actually built — a hand-constructed alias ARN string there never grants `kms:Decrypt` at all,
   and this passes `terraform plan`/`apply` cleanly.** AWS KMS does not honor an alias ARN (
   `arn:aws:kms:*:<account>:alias/<name>`) as the `Resource` for cryptographic-operation actions
   (`kms:Decrypt`, `kms:Encrypt`, `kms:GenerateDataKey`, etc) — only a key ARN or key ID is
   evaluated for those; alias ARNs only work as a `Resource` for alias-management actions
   (`kms:CreateAlias`/`DeleteAlias`/`UpdateAlias`/`ListAliases`). A statement like:
   ```hcl
   resources = [
     var.newrelic_secret_kms_alias != "" ? "arn:aws:kms:*:${data.aws_caller_identity.current.account_id}:alias/${var.newrelic_secret_kms_alias}" : ""
   ]
   ```
   looks correct, passes `terraform validate`/`apply` with no error (it's a syntactically valid
   ARN), and even `secretsmanager:GetSecretValue` on the IAM simulator shows `allowed` — but
   `secretsmanager:GetSecretValue` on a CMK-encrypted secret calls `kms:Decrypt` internally, and
   that call gets an **implicit deny** because the policy's `Resource` never actually matches the
   real key. The result is a runtime-only failure (CommonInstaller's `Get-SecretManagerValue` /
   `aws.exe secretsmanager get-secret-value` fails on the instance, often with an unhelpfully empty
   error message in a Windows PowerShell transcript) that nothing at plan/apply time catches. This
   happened in practice: `ibd-iam`'s `policy-newrelic-shared.tf` had exactly this bug, confirmed by
   running `aws iam simulate-principal-policy --policy-source-arn <role-arn> --action-names
   kms:Decrypt --resource-arns <real-key-arn>` against the live account and getting `implicitDeny`
   while `secretsmanager:GetSecretValue` on the same role showed `allowed` — it broke every role
   sharing that one policy (`icom_ec2`, `icom_webhook_ec2`, `swingtrader_ec2`, `leaderboard_ec2`),
   not just the one that happened to surface it first. **Fix: resolve the alias to its target key
   ARN via a data source and use that, not a hand-built alias ARN string:**
   ```hcl
   data "aws_kms_alias" "newrelic" {
     count = var.newrelic_secret_kms_alias != "" ? 1 : 0
     name  = "alias/${var.newrelic_secret_kms_alias}"
   }
   ```
   ```hcl
   resources = [
     var.newrelic_secret_kms_alias != "" ? data.aws_kms_alias.newrelic[0].target_key_arn : ""
   ]
   ```
   **Check this on every shared KMS-decrypt policy you touch or activate in Step 8**, not just when
   something is visibly broken — a hand-built alias ARN in a `Resource` is wrong regardless of
   whether this specific migration happens to be the one that exercises it. If you have live AWS
   credentials for the account, verify with `aws iam simulate-principal-policy` against the real key
   ARN (not the alias) before trusting that `terraform plan` passing means the grant actually works.

4. **Clean up the IAM repo's own Jenkinsfile(s) the same way as Step 4, item 6** — same gating
   checks against `vars/terraform.groovy` and `vars/withArtifactoryOidcCredentials.groovy` (a
   confirmed-OIDC-aware result for the deploy repo's Jenkinsfile applies here too if both pin the
   same org-default library with no explicit ref; re-check if either pins its own), same four
   patterns (A: `backendConfig.username`/`password`, B: `backendConfig.token`, C: `docker.credential`,
   D: any other `withCredentials`-bound Artifactory credential wrapping a non-`terraform()` script
   block), same rule to only remove the Artifactory credential binding and leave unrelated bindings in
   a shared `withCredentials([...])` alone. Do this for every Jenkinsfile found in Step 7's discovery,
   not just one. This is easy to skip entirely because the rest of the IAM repo migration is pure
   Terraform — don't let that pattern match fool you into thinking the Jenkinsfile layer doesn't apply
   here too.

5. **ECS image-pull secret exception only** (see "EC2 vs ECS/build-only" above and Step 4, item 8) —
   grant the ECS task **execution** role read access to Platform Engineering's managed pull secret and
   its KMS key. **Target the task execution role, not the task role** — the task role needs nothing
   for image pulls (per the consumer guide). This role is very commonly shared across several
   unrelated services in the same account (e.g. a single `ecs-task-execution-role` reused by multiple
   deploy repos) — check `grep -rn "aws_iam_role_policy_attachment" <iam-repo>/global/role-*execution*.tf`
   to see what else is already attached before assuming this role is dedicated to the one project
   you're migrating.

   a. **Check whether the shared policy already exists** in this IAM repo before creating a new one:
   ```bash
   grep -rln "GetSecretValue.*artifactory\|djin-prod-artifactory-ecs-docker-ro" <iam-repo>/global/*.tf
   ```
   If it exists, just add the attachment (skip to step 5c). If not, create it following the repo's
   existing shared-policy convention — re-check
   `iam-oidc-artifactory-token-consumer-guide.md`'s "ECS / Fargate image pulls" section for the
   current secret/KMS ARNs before hardcoding them here, in case they've changed since this was
   written:
   ```hcl
   # policy-artifactory-ecs-pull-secret-shared.tf
   data "aws_iam_policy_document" "artifactory_ecs_pull_secret_iam_document" {
     statement {
       sid    = "ReadArtifactoryPullSecret"
       effect = "Allow"
       actions = [
         "secretsmanager:GetSecretValue"
       ]
       resources = [
         "arn:aws:secretsmanager:us-east-1:775258986048:secret:djin-prod-artifactory-ecs-docker-ro-*"
       ]
     }

     statement {
       sid    = "DecryptArtifactoryPullSecret"
       effect = "Allow"
       actions = [
         "kms:Decrypt"
       ]
       resources = [
         "arn:aws:kms:us-east-1:775258986048:key/781a4c14-b7c9-4dd4-ad6b-c79f500c32b7"
       ]
       condition {
         test     = "StringEquals"
         variable = "kms:ViaService"
         values   = ["secretsmanager.us-east-1.amazonaws.com"]
       }
     }
   }

   resource "aws_iam_policy" "artifactory_ecs_pull_secret_shared_policy" {
     count       = var.region_id == "us-east-1" ? 1 : 0
     name        = "mktdata_artifactory_ecs_pull_secret"
     description = "Policy to grant ECS execution roles read access to the managed Artifactory Docker pull secret"
     policy      = data.aws_iam_policy_document.artifactory_ecs_pull_secret_iam_document.json
   }
   ```
   Note the `resources` uses a **wildcard suffix** (`...-docker-ro-*`) on the secret ARN — unlike
   Step 4, item 8b's deploy-repo reference, which needs the exact suffixed ARN. The policy document
   can be a wildcard; the task definition's `credentials_param_arn` cannot.

   b. **Keep the condition on the KMS statement** (`kms:ViaService` = Secrets Manager) — it's what
   scopes the decrypt grant to only this use, rather than a bare grant on that KMS key for any
   service.

   c. **Attach the role to it**, the same `aws_iam_role_policy_attachment`-per-role convention as
   Step 8, item 2:
   ```hcl
   resource "aws_iam_role_policy_attachment" "ecs_task_execution_artifactory_ecs_pull_secret_iam_attachment" {
     role       = aws_iam_role.ecs_task_execution_role.id
     policy_arn = element(concat(aws_iam_policy.artifactory_ecs_pull_secret_shared_policy.*.arn, [""]), 0)
   }
   ```

   d. **Leave the legacy Artifactory secrets-policy attachment on this role in place** (don't apply
   Step 8, item 1's removal here) **if any other service still using the same shared execution role
   hasn't migrated yet** — check what else attaches to it (per the grep above) and ask the user if
   it's unclear. Dropping the legacy attachment while a sibling service still depends on it breaks
   that sibling's image pulls. Only remove it once every consumer of that specific role has migrated.

---

## Step 9 — Validate the IAM repo changes

*(Items 1-4's gating: EC2-type components only — see "EC2 vs ECS/build-only" above, skip entirely
for an ECS/build-only component. If only item 5 (the ECS pull-secret exception) applied in Step 8,
still run this validation for that change.)*

```bash
terraform fmt -check -diff global/
```

Same caveat as Step 5 — `terraform validate` may not be runnable without private module access;
`terraform fmt -check` is the practical bar here.

---

## Step 10 — Commit the IAM repo (do not push yet)

*(EC2-type components only — see "EC2 vs ECS/build-only" above. Skip entirely for an ECS/build-only
component — except if Step 8, item 5's pull-secret grant applied, in which case commit that change
here too.)*

Stage only the files actually changed and commit. Do not push.

---

## Step 11 — Register the role for RO in dj-terraform-aws-artifactory-token-management

*(EC2-type components only — see "EC2 vs ECS/build-only" above. Skip entirely for ECS or build-only
projects, along with the rest of Steps 7-10 — they run strictly in Jenkins and already have
whatever OIDC/secrets permissions they need there.)*

The IAM permission from Step 8 only lets the role *call* `sts:GetWebIdentityToken` — since
2026-10-29 that account's RO catch-all no longer exists, so the role also needs a dedicated
`extra_ro_mappings` entry or it gets a token-exchange error at runtime. This is a separate repo
(`newscorp-ghfb/dj-terraform-aws-artifactory-token-management`) from the deploy and IAM repos above,
and this step pushes and opens a PR directly (see the note in the overview) rather than stopping
for confirmation like Steps 6/10 do.

The canonical, maintained procedure for this already exists in that repo as
`.sandcastle/commands/add-oidc-ro-role.md` — read it first and follow it; the summary below is just
how it plugs into this skill's flow, not a replacement for it.

1. **Check out and branch:**
   ```bash
   cd <dj-terraform-aws-artifactory-token-management repo>
   git status                       # make sure there's nothing uncommitted to stash/lose
   git checkout main && git pull origin main
   git checkout -b feature/register-<project>-ro-access
   ```

2. **Resolve every (account, role ARN) pair** the deploy project needs, one per environment it
   actually runs in (e.g. nonprod/stag/prod), using the account IDs and role name identified in
   Step 7/8. Build the full ARN: `arn:aws:iam::<account-id>:role/<role-name>` (include the path if
   the role has one — don't shorten it).

3. **For each account, confirm it's onboarded:**
   ```bash
   grep -n '"<account-id>"' accounts/iam-federation/prod/variables.tf
   ```
   If the account isn't in `var.accounts` at all, **stop and tell the user to route this to
   Platform Engineering** — every DJ account should already be onboarded; this skill does not add a
   new account entry from scratch (that needs an `issuer_url` captured from a decoded
   `GetWebIdentityToken` JWT in that account, which this skill has no way to obtain).

4. **Check the role isn't already registered:**
   ```bash
   grep -n '<role-arn>' accounts/iam-federation/prod/variables.tf
   ```
   If it already appears in an `extra_ro_mappings` entry for that account, skip that account — note
   it to the user and move on. (If it only appears in an `extra_rw_mappings` entry, that's a
   *different* token/scope — still register RO separately, same as the upstream Sandcastle doc says.)

4a. **Check every other OPEN PR against this repo for a priority collision on the same account(s) —
    `main` alone is not enough.** Each registration PR branches from `main` at whatever point it
    happened to be cut, so two PRs opened close together (e.g. migrating several deploy projects in
    the same session, back to back) will each independently compute "next unused priority" from the
    *same* stale `main` and land on the same number — a real collision that has actually happened in
    practice (three separate RO-registration PRs for three different projects all added `priority = 2`
    to the same three accounts, because each was branched before the others merged). `terraform
    validate` does not catch this — Terraform doesn't require list-item priorities to be globally
    unique at plan time the way JFrog's matching semantics care about it being unambiguous at runtime.
    Check open PRs before computing the priority to use:
    ```bash
    gh pr list --state open --json number,title,headRefName,baseRefName --jq '.[] | select(.baseRefName=="main")'
    # for each other open PR, check whether it touches the same account block:
    gh pr diff <other-pr-number> -- accounts/iam-federation/prod/variables.tf | grep -n '"<account-id>"' -A20
    ```
    If any other open PR already adds an `extra_ro_mappings` entry to the same account at the
    priority you were about to use (almost always because both PRs still show `priority = 2`, since
    both last saw only the original catch-all-removal entry at `priority = 1` on `main`), pick a
    priority higher than every priority already used for that account **across both `main` and every
    other open PR that touches it** — not just higher than what's on `main`. Note the collision and
    the other PR number(s) to the user either way, even if you end up picking a number that happens
    not to collide.

5. **If the account already has `extra_ro_mappings` entries, show them to the user and ask** whether
   to (a) add this role as a new, separate entry (the convention this repo's own Sandcastle doc
   uses — one role per entry, named `<role-name>-ro`), or (b) fold this role's ARN into an existing
   entry's `claims_json.sub` list if it's clearly the same purpose/blast-radius as that entry (JFrog
   matches a `sub` list as any-of). Don't pick silently — the repo's own convention favors (a)
   unless the user has a specific reason for (b). If the account has no `extra_ro_mappings` yet,
   there's nothing to ask — just add the first one.

6. **Edit `accounts/iam-federation/prod/variables.tf`** following `add-oidc-ro-role.md`'s steps 2-5
   exactly: derive the name as `<role-name>-ro` (or disambiguate with the ARN path if that
   collides), expand a one-line account entry to multi-line if needed (keep its trailing `# <env>`
   comment after the closing brace), append with the next unused `priority` from step 4a's check
   (next unused across `main` *and* every other open PR touching that account, not just `main`) if
   the list already has entries. **Never** set or touch `enable_ro_catchall`/`ro_catchall_priority` —
   the catch-all is gone everywhere and this skill does not resurrect it.

7. **Validate:**
   ```bash
   grep -n '<role-name>-ro' accounts/iam-federation/prod/variables.tf
   git diff --stat   # should be exactly accounts/iam-federation/prod/variables.tf
   terraform fmt -check -diff accounts/iam-federation/prod/
   cd accounts/iam-federation/prod && terraform init -backend=false -input=false && terraform validate
   ```
   Don't hand-edit `artifactory-oidc-access.md` — a CI workflow regenerates and commits it onto the
   PR branch automatically. **This means if you come back to push a follow-up fix to an already-open
   PR from this step (e.g. a priority-collision fix from item 4a), a plain `git push` will be
   rejected** — the CI commit is now on the remote branch and your local branch doesn't have it.
   `git fetch origin <branch>` then `git rebase origin/<branch>` (or a fast-forward merge if you have
   no new local commits yet) before pushing again.

8. **Commit, push, and open the PR:**
   ```bash
   git add accounts/iam-federation/prod/variables.tf
   git commit -m "..."   # describe the role(s)/account(s) registered and why
   git push -u origin feature/register-<project>-ro-access
   gh pr create --base main --title "..." --body "..."
   ```
   Follow this repo's own commit/PR conventions and any attribution-line instructions already in
   effect for this session. Note in the PR body (per `add-oidc-ro-role.md`'s mistake-prevention
   list) that the token's `sub` becomes `aws-iam-ro-<account>/<name>` — relevant only to Basic-auth
   consumers that hardcode the username instead of reading it from the token.

9. **After pushing, actively watch for and fix merge conflicts against sibling open PRs — don't just
   flag the risk in step 4a and move on.** `gh pr view <pr> --json mergeable` only computes against
   the *current* base branch, so a same-account collision caught in step 4a still shows this PR as
   cleanly mergeable right after you push it — the real conflict only appears once whichever sibling
   PR touching the same account merges first. This has actually happened in practice: several
   RO-registration PRs editing the same `extra_ro_mappings` list each inserted their new `{ ... }`
   entry at the same place (right before the list's closing `]`), so merging them one after another
   produced textual conflicts on the brackets — and a careless conflict resolution there risks
   silently dropping one side's entry. Whenever a sibling RO-registration PR you know is in flight
   merges (check with `gh pr view <sibling-pr> --json state,mergedAt`), re-check this PR's own status:
   ```bash
   gh pr view <this-pr> --json mergeable,mergeStateStatus
   ```
   If `mergeable` is `CONFLICTING` (`mergeStateStatus` `DIRTY`), fix it immediately rather than
   leaving it for whoever merges next to untangle blind:
   ```bash
   git checkout feature/register-<project>-ro-access
   git fetch origin main
   git merge origin/main   # merge, not rebase -- avoids a force-push to an already-open PR
   ```
   The conflict will show up as both sides adding a `{ ... }` block at/near the same spot in the
   same account's `extra_ro_mappings` list (and often the same `priority` value, if step 4a's check
   was skipped or a third PR opened after it). **Resolve by keeping both entries — never drop
   either side.** This is an additive list; a conflict here almost always means "someone else's
   entry landed next to mine," not a real contradiction. If both sides ended up with the same
   `priority`, renumber one while resolving so the merged file has no duplicate priority for that
   account. Re-run `terraform validate` after resolving, then push the merge commit (not a
   force-push) so the PR updates cleanly.

   **This fix is not one-shot when several RO-registration PRs are open at once — re-check right
   before this PR is actually merged, not just once after the first conflict.** Each additional
   sibling PR that merges while this one is still open can reintroduce the exact same conflict, since
   it reopens the same insertion point in the same list. This has actually happened in practice: a
   PR was fixed clean against `main`, then a *second* sibling PR (not the one that caused the first
   conflict) merged before this one did, flipping it back to `CONFLICTING` — requiring the same
   `git merge origin/main` fix a second time. If you know several RO-registration PRs for different
   projects are open concurrently against the same accounts, treat "mergeable" as provisional until
   this PR itself has merged: re-run the `gh pr view <this-pr> --json mergeable,mergeStateStatus`
   check once more immediately before advising the user it's ready to merge, and expect to repeat
   the merge-and-resolve step again if another sibling lands first. If three or more such PRs end up
   open at the same time, it is worth telling the user that merging the open ones promptly (so fewer
   stay open concurrently) reduces how many times this repeats — this skill still opens one PR per
   project rather than batching them, but the user may choose to merge them in quick succession.

10. **Tell the user the two follow-ups that happen outside this skill's reach**, per
   `add-oidc-ro-role.md`'s Validation section: after the PR merges and applies, they should see
   `+ platform_oidc_identity_mapping.ro_extra["<name>"]` (and nothing else) in the plan, and the
   role owner should run `scripts/get-artifactory-token.sh` from the role afterward to confirm the
   token's `sub` ends in `/<name>`.

---

## Step 12 — Hand off for review (deploy + IAM repos)

For a purely ECS/build-only component, there's only the deploy repo's Jenkinsfile commit to hand
off — no IAM repo involvement, so skip anything below that refers to the IAM repo. **Exception:** if
the ECS image-pull secret migration (Step 4, item 8 / Step 8, item 5) applied, hand off both repos —
flag explicitly that the deploy-repo PR has a hard dependency on the IAM-repo PR merging/applying
first (image pulls fail otherwise), so the user merges them in that order.

Show the user, for the deploy and IAM repos:
- `git diff --stat` and `git log -1` for the new commit
- A short summary of what was added/removed and why

Then explicitly ask whether to push and open PRs now. Only after the user confirms:

```bash
git push -u origin feature/secrets-manager-oidc-migration   # in each repo
gh pr create --base develop --title "..." --body "..."       # in each repo
```

Follow each repo's own commit/PR message conventions and any attribution-line instructions already in
effect for this session.

---

## Tolerance / idempotency rules

| Situation | Behavior |
|---|---|
| `secretId` already used for every enabled secret-needing addon, no old pattern left | Report already migrated, stop |
| Some addons already migrated, others not | Only touch the ones still on the old pattern |
| Old `aws_secretsmanager_secret_version` data source still referenced elsewhere in the repo | Don't remove it — flag to the user and ask |
| IAM role already has `sts:GetWebIdentityToken` | Skip adding it, just confirm it's there |
| No shared IAM policy exists for a needed secret | Stop and ask — don't create Secrets Manager grants unprompted |
| File becomes empty after removing all its contents | Leave it emptied, don't `git rm` it; mention it to the user |
| Deploy repo has uncommitted changes before pulling develop | Stash or ask first — never discard |
| Shared EC2 module's bootstrap template still requires `accessKey` (Step 0) | Don't remove `accessKey` from the deploy repo — flag the module gap and ask how to proceed |
| A shared KMS-decrypt policy's `Resource` is a hand-built alias ARN rather than a resolved key ARN (Step 8, item 3b) | Fix it regardless of whether this migration is the one that surfaces the breakage — `terraform plan`/`apply` won't catch it, and it silently breaks `kms:Decrypt` (hence `secretsmanager:GetSecretValue` on a CMK-encrypted secret) for every role sharing that policy |
| Role already has an `extra_ro_mappings` entry in that account (Step 11) | Skip that account, note it, move on — don't duplicate |
| Account not yet onboarded in `accounts/iam-federation/prod/variables.tf`'s `var.accounts` (Step 11) | Stop and tell the user to route it to Platform Engineering — this skill doesn't onboard new accounts (needs a captured `issuer_url` it has no way to obtain) |
| Jenkinsfile's pinned `dj-shared` ref does not yet reject all three of `backendConfig.username`/`password`, `backendConfig.token`, and `docker.credential` (Step 4, item 6; Step 8, item 4) | Don't remove any `withCredentials`/`backendConfig`/`docker.credential` wiring yet — flag it and ask about bumping the library ref, same as an unfixed shared EC2 module in Step 0 |
| Jenkinsfile's pinned `dj-shared` ref does not yet have `vars/withArtifactoryOidcCredentials.groovy` (Pattern D's own gating check, Step 4, item 6; Step 8, item 4) | Leave that Pattern D candidate's `withCredentials` wiring in place even if Patterns A-C are otherwise safe to migrate on the same ref — it's a separate step added later; flag it and ask about bumping the ref |
| A build-only Jenkinsfile has none of Patterns A-C (no `terraform()` call at all) | Don't conclude there's nothing to migrate — check for Pattern D independently; it's commonly the *only* applicable pattern for build-only projects |
| Deploy repo's `instance_profile_name` matches a role already migrated for a sibling project this session | Skip Steps 7-11 entirely for this project — the IAM grant and RO registration already cover the shared role; do the deploy-repo Terraform/Jenkinsfile work only, and say in the commit/PR body which repo/PR already covers the IAM side |
| Another OPEN PR against `dj-terraform-aws-artifactory-token-management` already uses the priority you were about to assign for the same account (Step 11, item 4a) | Pick a priority higher than every priority already used for that account across `main` *and* every other open PR — don't just take the next unused value on `main` |
| Assuming a RO-registration PR is safe to leave alone because `gh pr view` showed `mergeable: MERGEABLE` right after pushing it | That status is computed against the base branch *at that moment* — it flips to `CONFLICTING` only once a sibling PR editing the same account's `extra_ro_mappings` list actually merges first. Re-check and fix then (Step 11, item 9), don't treat the push-time status as permanent |
| Jenkinsfile's `terraform()` call already has none of the three patterns | Already migrated at this layer — skip |
| IAM repo has no Jenkinsfile, or its Jenkinsfile doesn't call `dj-shared`'s `terraform()` step | Nothing to clean up at this layer for the IAM repo — skip Step 8, item 4 |
| `installer_config.installer.version` already matches or exceeds its installer's current major-version baseline (`entry = "CommonInstaller-aws.ps1"` → `"3.0.*"`; `entry = "CommonInstaller.sh"` → `"3.1.*"`) | Already current (or newer) — skip, don't downgrade (Step 4, item 7) |
| A deploy component is ECS-type or build-only (no `installer_config`; uses `ecs_service`/`host_match_rule`/`aws_ecs_service`/`aws_ecs_task_definition`, or has no deploy-target Terraform at all) | Skip Steps 0-3, Step 4 items 1-5 and 7, Step 5, and Steps 7-11 entirely for that component. Only do Step 4, item 6 (Jenkinsfile credential cleanup), then Step 6 and Step 12 for the deploy repo alone — no IAM repo involvement at all (see "EC2 vs ECS/build-only") — **unless** the ECS component's image pull is still on the old static-secret pattern (next row) |
| An ECS component's task definition still resolves its own image-pull credential via a dynamic `data "aws_secretsmanager_secret"` lookup (`credentials_param_arn`/`repositoryCredentials`), instead of Platform Engineering's managed pull secret | This is the one exception to the row above — do Step 4, item 8 (deploy repo: hardcode the managed secret ARN, move the image to `dj-docker-virtual`) *and* Step 8, item 5 (IAM repo: grant the ECS task execution role read access to that secret + its KMS key), in addition to Step 4 item 6. Nothing else in Steps 0-3/5/7/9-11 applies — see the "Exception" callout under "EC2 vs ECS/build-only" |
| The shared ECS task execution role targeted by Step 8, item 5 already has other, not-yet-migrated services attached to its legacy Artifactory secrets-policy attachment | Leave that legacy attachment in place — only add the new managed-pull-secret policy/attachment alongside it. Don't remove the legacy one (Step 8, item 1) until every service sharing that role has migrated |

---

## Common mistakes

| Mistake | Fix |
|---|---|
| Assuming the IAM repo is always `mktdata-iam` | Ask and confirm — different projects may use a different IAM repo |
| Inventing a Secrets Manager secret name | Always ask the user; offer known standards as defaults only |
| Removing a `aws_secretsmanager_secret_version` data source without checking for other consumers | Grep the whole repo first |
| Using `git rm` on a file you emptied out | Treated as destructive — leave it emptied and ask the user whether to actually delete it |
| Pushing/opening a PR without asking first | Always stop after the local commit and get explicit confirmation |
| Doubting that `aws sts get-web-identity-token` is real | It is — requires a current AWS CLI v2; see `Get-ArtifactoryToken` in CommonInstaller's `shared-functions.ps1` |
| Setting a shared policy's secret-name variable (e.g. `newrelic_secret_name`) without checking for a companion KMS-alias variable the same module expects | Run the Step 2 KMS lookup (`aws secretsmanager describe-secret` + `aws kms list-aliases`) for every secret and set both variables together — otherwise `terraform plan`/`validate` pass clean and the break only surfaces as a `MalformedPolicyDocument` at real `apply` time |
| Assuming a KMS alias matches the secret/app name exactly | Some accounts have aliases with extra/unexpected prefixes baked into the literal name (e.g. `alias/alias/newrelic`) — always use what `aws kms list-aliases` actually returns, matched by `TargetKeyId`, not a guessed name |
| Trusting a KMS-decrypt statement whose `Resource` is a hand-built alias ARN (`arn:...:alias/<name>`) just because `terraform plan`/`apply` pass clean | AWS KMS only evaluates a key ARN or key ID as the `Resource` for crypto-operation actions (`kms:Decrypt`/`Encrypt`/etc) — an alias ARN there silently never grants access, `terraform` has no way to catch it, and it only surfaces as a runtime `secretsmanager:GetSecretValue` failure on a CMK-encrypted secret (often with no useful error text on Windows). Resolve the alias to `target_key_arn` via a `data "aws_kms_alias"` lookup instead, and if you have live AWS creds, confirm with `aws iam simulate-principal-policy` against the real key ARN rather than trusting the plan (Step 8, item 3b) |
| Sending the JFrog OIDC exchange as form-urlencoded | JFrog rejects that with HTTP 415 — it must be a JSON body |
| Giving Artifactory a Secrets Manager IAM grant | Not needed anymore — Artifactory auth is now pure OIDC/STS, no secret involved |
| Forgetting to revert a `# TEMPORARY` installer branch pin | Note it in the tfvars comment and remind the user once CommonInstaller's change is merged and published |
| Removing `installer_config.artifactory.accessKey` without checking the shared EC2 module's own bootstrap template | The module (e.g. `dj-terracycle` `ec2_instance`/`ec2_stack`) often has a `variables.tf` validation requiring `accessKey` non-blank, and a `templates/linux_user_data.sh`/`windows_user_data.ps1` that builds its own header from it to fetch the installer zip itself — independent of anything inside CommonInstaller. Always run Step 0 first. |
| Assuming a fixed `stack/<project>/` layout | Some projects put `installer_config` directly at the repo root (e.g. `factset/`) or elsewhere — search for it, don't assume |
| Adding `sts:GetWebIdentityToken` as an inline statement on one role's own policy | Make it a shared policy (`artifactory_oidc_shared_policy` or whatever already exists) attached via `aws_iam_role_policy_attachment`, so the next role to migrate attaches instead of duplicating the statement — see Step 8.2 |
| Repurposing an existing secrets-based shared policy (e.g. `artifactory_shared_policy`) for the new OIDC grant | Check first whether other, not-yet-migrated roles still attach to it (`grep` for `aws_iam_policy.<name>.*.arn`) — if so, leave it alone and add a new policy instead |
| Thinking `sts:GetWebIdentityToken` in the IAM repo is the whole fix | It only lets the role call STS — since 2026-10-29 the role also needs an `extra_ro_mappings` entry in `dj-terraform-aws-artifactory-token-management` (Step 11) or the token exchange itself fails with no RO catch-all left to fall back on |
| Computing the "next unused `priority`" for an `extra_ro_mappings` entry from `main` alone | Check every other OPEN PR touching the same account block too (Step 11.4a) — two registration PRs cut close together both see the same stale `main` and will independently pick the same priority; this has actually happened across three separate RO-registration PRs for three different projects, all landing on `priority = 2` for the same three accounts |
| Setting or touching `enable_ro_catchall`/`ro_catchall_priority` to "fix" a missing RO token | Don't — the catch-all is removed in every account on purpose (2026-10-29); register the specific role instead |
| Assuming the deploying account shares the project's name (e.g. "dylan" account) | Many projects deploy into a shared-services account (e.g. `shdsvc`) used by multiple unrelated teams — don't guess from the project name |
| Trusting the first account-ID-shaped locals map found in the IAM repo as "the deployment account mapping" (this has actually happened — see "Resolving the deploy account(s)" under Inputs) | Grep every place that map is *referenced*, not just where it's defined, before trusting it — it may build a cross-account ARN for an unrelated resource. The IAM repo's own Terraform frequently doesn't know its own deployment account at all (injected by CI); resolve the account from the deploy repo's backend/provider config or its shared module's landing-zone registry instead, and say the resolved account IDs back to the user before editing the third repo |
| Stripping a Jenkinsfile's `backendConfig`/`docker` credential parameters before confirming the pinned `dj-shared` ref actually rejects all three (Step 4, item 6; Step 8, item 4) | Check first — older refs still require these parameters; removing them while pinned to one supplies no credentials where the old code path expected them and breaks the build, often on a *different* parameter than the one you were thinking of (e.g. `docker.credential` fails before `backendConfig.token` is ever reached, since that map is validated first) |
| Applying Pattern D (`withArtifactoryOidcCredentials`) using the same gating check as Patterns A-C (`vars/terraform.groovy`'s "no longer supported" strings) | Pattern D is a different, independently-added step — check `vars/withArtifactoryOidcCredentials.groovy` exists at the pinned ref separately; a ref can be OIDC-aware for A-C and still predate Pattern D |
| Assuming `withArtifactoryOidcCredentials` is a drop-in replacement for a single-value `string(...)` credential binding | It always produces a username+password pair, not a bare token var — for a script that uses the old binding as a single bearer value, point the body's existing variable name at the new step's `passwordVariable`; for `X-JFrog-Art-Api`-header usage there is no OIDC equivalent at all, so flag it rather than guessing a replacement |
| Only looking for Pattern D near an existing `terraform()` call, or only in repos that already show Patterns A-C | Pattern D is independent of `terraform()` entirely and is often the *only* pattern present in a build-only Jenkinsfile — check every `stage` in every Jenkinsfile for an Artifactory-credentialed `withCredentials`, regardless of whether `terraform()` appears anywhere in the file |
| Deleting an entire `withCredentials([...])` block because one of its bindings is now unused | Only remove the specific binding entry for the Artifactory credential; leave other, unrelated bindings (e.g. an Apollo key) alone and only unwrap the step if the list becomes empty |
| Migrating the deploy repo's Jenkinsfile(s) (Step 4, item 6) and treating the IAM repo as Terraform-only, so its own Jenkinsfile keeps the same credential wiring | The IAM repo almost always has its own `Jenkinsfile` driving its own `terraform apply`, independent of the deploy repo's — always run Step 8, item 4 too; this has actually been missed in practice on a real migration (caught only after the fact, as a follow-up commit to the already-open IAM repo PR) |
| Leaving `installer_config.installer.version` pinned to a stale major-version wildcard (e.g. `"2.1.*"`) | Check `installer_config.installer.entry` to know which installer/baseline applies (`CommonInstaller-aws.ps1` → `"3.0.*"` from `build.ps1`; `CommonInstaller.sh` → `"3.1.*"` from `Jenkinsfile.build`'s `major_version`), both on `develop`, and bump to match — a stale wildcard matches no currently-published package and breaks provisioning at boot, independent of whether the rest of the secrets-manager migration is otherwise already done (Step 4, item 7) |
| Applying the PowerShell installer's version baseline (`"3.0.*"`) to a Linux project, or vice versa | Check `installer_config.installer.entry` first — `CommonInstaller-aws.ps1` and `CommonInstaller.sh` are two unrelated installers with two unrelated version lines; they are not interchangeable (Step 4, item 7) |
| Applying the full EC2 migration (installer_config edits, IAM repo changes, RO registration) to an ECS/build-only component | ECS tasks and build-only pipelines run strictly in Jenkins and have no separate runtime IAM identity needing the Artifactory OIDC grant — classify each component first ("EC2 vs ECS/build-only" near the top) and scope ECS/build-only ones to Jenkinsfile-only cleanup (Step 4, item 6), skipping the IAM repo and RO registration entirely |
| Assuming one component's EC2/ECS/build-only classification applies to the whole repo | A repo commonly has more than one component (`infrastructure`/`stack`/`switch`), and they can be different types — classify each independently, don't extrapolate from the first one checked |
| Treating an ECS component's image-pull-secret migration (Step 4, item 8) as covered by the general "ECS is Jenkinsfile-only" rule | It's an exception to that rule — the task definition's own `credentials_param_arn` is a completely different mechanism (image pulls, not the Terraform backend/OIDC `sts:GetWebIdentityToken` pattern) and still needs both a deploy-repo Terraform edit and an IAM-repo grant |
| Granting the ECS **task role** instead of the task **execution** role for the managed pull secret (Step 8, item 5) | The task role needs nothing for image pulls — only the execution role reads the secret, since the pull happens before the container (and its task role) exists |
| Hardcoding the managed pull secret's ARN/KMS values into the skill from memory without checking the consumer guide first | The secret's ARN suffix changes if it's ever recreated — `iam-oidc-artifactory-token-consumer-guide.md`'s "ECS / Fargate image pulls" section is the source of truth; re-check it rather than trusting a stale copy here |
