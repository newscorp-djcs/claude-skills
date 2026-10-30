# migrate-secrets-oidc

A Claude Code skill that migrates a CommonInstaller-based deploy project off
plaintext/Terraform-resolved secrets and static Artifactory credentials, onto:

1. **Runtime AWS Secrets Manager fetch** — addons that need a secret (New Relic
   license key, CrowdStrike CID, etc.) take a `secretId` in their `AppConfig`
   entry instead of a resolved value. CommonInstaller fetches it at boot via
   the AWS CLI. Terraform never sees the secret's value, only its name/ARN.
2. **OIDC Artifactory auth** — no secret at all. The consuming identity (an
   EC2 instance role, or the Jenkins pipeline itself) exchanges its own AWS
   IAM identity for a short-lived JFrog access token via
   `sts:GetWebIdentityToken` + JFrog's OIDC token-exchange endpoint.

This is the pattern introduced in `MarketData/CommonInstaller` PR #195 and
mirrored in `Quest/LinuxCommonInstaller` PR #96. The skill does not touch
CommonInstaller/LinuxCommonInstaller itself — it migrates *consumers* of one
of them.

## Installation

This skill ships as a plugin in the `claude-skills` marketplace (this repo's
root). See the top-level [`README.md`](../README.md) for the
`/plugin marketplace add` / `/plugin install` commands.

To install manually instead, copy the `migrate-secrets-oidc` folder into your
user-level skills directory:

```bash
cp -r migrate-secrets-oidc ~/.claude/skills/
```

Claude Code picks up skills from `~/.claude/skills/<name>/SKILL.md`
automatically — no further setup needed.

## When to use it

Ask Claude to migrate a project using any of these phrasings:

- "migrate this project to the new secrets pattern"
- "move off the static Artifactory key"
- "apply the secrets-manager-runtime-fetch pattern"
- "update IAM for the new CommonInstaller secrets/OIDC flow"
- "register a role for Artifactory RO/OIDC access"
- "clean up the Jenkinsfile credentials for this ECS project"
- "remove Artifactory credentials from this build-only project"
- "move this ECS task off the static Artifactory pull secret to the managed pull secret"

## What it touches

Depending on how a deploy component is classified, the skill can span up to
**three separate repos**, plus any Jenkinsfiles in the first two:

| Repo | What changes | When |
|---|---|---|
| **Deploy repo** (the Terraform "stack" building EC2 user-data, or an ECS task) | `AppConfig`/`installer_config` secrets switch to `secretId`; static `accessKey` removed; Jenkinsfile credential cleanup (see Jenkinsfile patterns below) | Always, if any old-pattern usage is found |
| **IAM repo** (commonly `mktdata-iam`, but confirm — never assume) | Grants the EC2 instance role `sts:GetWebIdentityToken` and any needed Secrets Manager/KMS access; same Jenkinsfile cleanup as the deploy repo, independently | EC2-based components only — skipped entirely for ECS/build-only |
| **`dj-terraform-aws-artifactory-token-management`** | Registers the role as an `extra_ro_mappings` entry so its OIDC token exchange actually succeeds (the account-wide RO catch-all was removed 2026-10-29) | EC2-based components only |

### EC2 vs ECS/build-only

The skill classifies each deploy component before doing anything else:

- **EC2-based** (has `installer_config`): full scope above — deploy repo,
  IAM repo, and RO registration.
- **ECS-based or build-only** (no separate runtime identity outside Jenkins):
  scope narrows to Jenkinsfile-only credential cleanup in the deploy repo. No
  IAM repo or RO-registration changes, since there's no runtime identity to
  grant anything to. Exception: if the ECS task definition still resolves its
  image-pull credential via a dynamic Secrets Manager lookup, that needs a
  narrower deploy-repo Terraform edit plus an IAM-repo grant on the task
  *execution* role — see the skill's "EC2 vs ECS/build-only" section.

### Jenkinsfile credential patterns (A-D)

Independent of the Terraform work above, any Jenkinsfile in either the
deploy repo or the IAM repo that fetches a static Artifactory credential gets
cleaned up once the pinned `dj-shared` library ref is OIDC-aware:

| Pattern | What it looks like | Replacement |
|---|---|---|
| A | `backendConfig.username`/`password` passed into `terraform()` | Dropped — `terraform()` now fetches its own OIDC token |
| B | `backendConfig.token` (remote backend) passed into `terraform()` | Dropped — same |
| C | `docker.credential` passed into `terraform()` | Dropped — same |
| D | Any other `withCredentials`-bound Artifactory credential wrapping an arbitrary script block (curl, docker login, npm, etc.), not going through `terraform()` at all | `dj-shared`'s `withArtifactoryOidcCredentials` step |

Pattern D is the common (often *only*) case for build-only/ECS Jenkinsfiles
that never call `terraform()`. Each pattern has its own gating check against
the pinned library ref — see "Tolerance / idempotency rules" in `SKILL.md`.

Pattern D isn't limited to `sh`/shell credential bodies, and it isn't limited
to projects that skip Terraform entirely. Two sub-cases, found while reviewing
`AdTech/Seawolf/terraform/Jenkinsfile`, get the same `withArtifactoryOidcCredentials`
treatment:

- A Groovy-level call into the Jenkins Artifactory Plugin (`Artifactory.newServer(...)`)
  that reads its `username`/`password` from a `withCredentials` block, rather than
  shelling out to `curl`.
- A hand-rolled `terraform init`/`apply` invocation that bypasses `dj-shared`'s
  `terraform()` step entirely (calls the `terraform` binary directly inside a
  `sh` block) — don't mistake this for Pattern A, which only applies when the
  Jenkinsfile actually calls `terraform()`.

See the Pattern D section in `SKILL.md` for the full before/after examples.

## Safety model

For the deploy repo and IAM repo, the skill **stops short of pushing or
opening PRs** — it makes local commits, shows the diffs, and waits for
explicit go-ahead before `git push`/`gh pr create`. The RO-registration repo
is the one exception: that's a narrow, single-file, CI-reviewed change, so
the skill commits, pushes to a new branch, and opens the PR directly — the PR
review *is* the gate there.

## How it works

The skill walks through numbered steps (see `SKILL.md` for the full detail
behind each):

0. Check for a bootstrap-level Artifactory dependency in a shared EC2 module,
   before touching anything.
1. Discover current state in the deploy repo (old-pattern indicators,
   Jenkinsfiles, installer version baseline, ECS image-pull pattern).
2. Confirm secrets and naming with the user — never invent a secret name.
3. Branch the deploy repo.
4. Edit the deploy repo's Terraform and Jenkinsfile(s).
5. Validate the deploy repo changes.
6. Commit the deploy repo (don't push yet).
7. Discover and confirm the IAM repo + role (EC2-based only).
8. Edit the IAM repo's Terraform and Jenkinsfile(s).
9. Validate the IAM repo changes.
10. Commit the IAM repo (don't push yet).
11. Register the role for RO access in
    `dj-terraform-aws-artifactory-token-management` — commits, pushes, and
    opens the PR directly.
12. Hand off the deploy + IAM repo commits for review once the user gives the
    go-ahead to push.

## More detail

`SKILL.md` in this folder is the authoritative, step-by-step reference the
skill actually runs on — including the full inputs table, account-resolution
guidance, tolerance/idempotency rules, and a running list of mistakes this
skill has actually made in practice (and their fixes). This README is a map
of that document, not a replacement for it.
