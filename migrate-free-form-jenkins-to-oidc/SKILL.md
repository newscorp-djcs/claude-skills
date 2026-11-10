---
name: migrate-free-form-jenkins-to-oidc
description: For Dow Jones Jenkins, GitHub and Artifactory. Replace a static Artifactory Jenkins credential (withCredentials usernamePassword/string) in a free-form scripted Jenkinsfile with no shared pipeline library with short-lived Artifactory tokens minted at runtime from the Jenkins node's AWS identity (aws sts get-web-identity-token, then JFrog OIDC token exchange). Uses a read-write token only when Terraform uses the Artifactory backend or the job uploads to Artifactory, and read-only otherwise. Pastes a tested Groovy helper block that needs no extra Jenkins plugins or script approval and masks the token in all console output (including set -x and TF_LOG=DEBUG/TRACE). Commits, pushes and opens the PR by default. Use when asked to move a scripted/free-form Jenkinsfile to OIDC or short-lived Artifactory tokens, or to remove its static Artifactory credential. Not for Jenkinsfiles that call a shared library's terraform() step (use the shared-library OIDC migration skill) or non-Dow Jones Jenkins/Artifactory.
---

# Migrate a free-form Jenkinsfile to short-lived Artifactory tokens

Built for **Dow Jones CI/CD workflows**: Dow Jones Jenkins servers whose nodes run in Dow Jones AWS
accounts, building Dow Jones GitHub repos against the Dow Jones Artifactory. The helper hard-codes the
values that setup needs: the STS audiences, the JFrog OIDC provider-name pattern and the token-exchange
endpoint (all listed under "Choosing the scope").

Replaces a static Artifactory credential stored in Jenkins with a token minted per use:

```
Jenkins node IAM role --aws sts get-web-identity-token--> AWS-signed JWT
    --POST /access/api/v1/oidc/token--> short-lived Artifactory access token (RO or RW)
```

Files next to this one:

- `scripts/artifactory-oidc-helpers.groovy`: the helper block to paste into the Jenkinsfile.
- `scripts/verify-helpers.sh`: an offline check of the pasted block, with mocks in `scripts/mocks/`.

The helper block has been tested in a real Jenkins run with the RW scope and the Terraform Artifactory
backend.

## When to use it

- **Use it for** scripted or free-form Jenkinsfiles with plain `sh` steps and no `@Library(...)`
  shared pipeline library. The Jenkinsfile reads Artifactory through a Jenkins credential, usually for
  a Terraform `backend "artifactory"`, or for `curl`/`npm`/`docker` against Artifactory.
- **Use it only in the Dow Jones CI/CD setup:** a Dow Jones Jenkins server, nodes in Dow Jones AWS
  accounts, and the Dow Jones Artifactory host. Typical signs in the repo are a
  `credentialsId: '<artifactory-credential-id>'` binding and a Terraform backend whose `url` points at
  the Dow Jones Artifactory host with a `repo = "<state-repo>"`.
- **Don't use it for** Jenkinsfiles that load a shared library with `@Library(...)` and call its
  `terraform(...)` step. Use the shared-library OIDC migration skill instead: the one whose description
  covers stripping Artifactory credentials from the shared library's `terraform()` step. Pick the
  business-unit variant when one matches the repo, otherwise the general one.
- **Don't use it as is for other business units or Artifactory instances.** The audiences, provider names
  and endpoint only exist in the Dow Jones setup. Elsewhere, stop and tell the user. Adapting it needs
  that platform's own OIDC providers and node registrations, so the values can't just be swapped.

## Prerequisites (outside the Jenkinsfile)

Check these with the user before changing anything, and repeat them in the final report:

1. **The IAM role of every Jenkins node that can run the job has `sts:GetWebIdentityToken`.** This means the
   controller (built-in node) and every agent node, because the `sh` steps run on whichever node
   picks up the stage. Minimal statement:
   ```json
   { "Effect": "Allow", "Action": "sts:GetWebIdentityToken", "Resource": "*" }
   ```
2. **Outbound web identity federation is turned on for each AWS account the nodes run in.** It is set
   once per account. Check with `aws iam get-outbound-web-identity-federation-info`.
3. **The node role is registered with Artifactory for each scope it uses.** The JFrog OIDC providers
   are `aws-iam-ro-<accountId>` and `aws-iam-rw-<accountId>`, managed in the Artifactory
   token-management Terraform repo. The shared-library OIDC migration skill describes how to register
   a role there.
4. **The nodes have these tools:** AWS CLI v2 recent enough to include `aws sts get-web-identity-token`,
   plus `curl`, `base64`, `cut` and `tr`. `/bin/bash` is required for the wrapped script.
5. **For Terraform:** the `artifactory` backend exists only up to Terraform 1.2. This skill keeps it.
   Migrating the backend itself is out of scope.

## Design rules (keep these when adapting the helpers)

1. **No extra Jenkins plugins.** Don't use `readJSON`, `httpRequest`, `MaskPasswordsBuildWrapper` or a
   shared pipeline library. The helpers must run on any Jenkins with only core Pipeline installed.
2. **No script approval.** Admins should not have to approve method signatures on each server. The
   Groovy may use only default-allowed calls: String methods, regex, lists, maps and `Integer.parseInt`.
   All of these trigger *In-process Script Approval* and must not be used: `.bytes`/`getBytes`,
   `encodeBase64`, `decodeBase64`, `new String(byte[], ...)`, `JsonOutput`, `JsonSlurper`,
   `java.util.Base64`, `padRight`, `intdiv` and `"cmd".execute()`. Do byte and base64 work in a `shQuiet` one-liner.
   Build small JSON bodies as strings, after checking every inserted value with `String.matches(...)`.
   The verifier fails if any of these calls appear in the block.
3. **Mask every credential, including debug output.** `withCredentials()` can't help here. It only
   masks secrets stored in Jenkins by `credentialsId`, not a token minted at runtime. The helper masks
   both the raw token and its Basic-auth form (`base64(user:token)`).
4. **Keep logic in Groovy.** Only the steps that need a process stay as one-line `sh` calls: the
   `aws sts` calls, `curl`, and the base64 one-liners. Don't move the flow into a bash script.
5. **No comments in the pasted block.** The helper block has no comments except the
   `// BEGIN Artifactory` and `// END Artifactory` marker lines. Don't add explanatory comments to it or
   to the call sites you rewrite; the rules in this file are the documentation.
6. **Open the PR by default.** Once offline verification passes, commit, push and open the PR without
   waiting for approval. Stop before committing only if the user asked to review the changes first,
   or if verification failed. Never merge.
7. **No real values as examples.** In this file and in anything you add to it, use placeholders such
   as `<repo>`, `<artifactory-credential-id>` or `<state-repo>` instead of real repo names, credential
   IDs, library names, state repos or commit hashes.

## Choosing the scope (RO vs RW)

**Use read-only (`ro`) by default.** Use read-write (`rw`) only in these two cases:

1. **Terraform uses Artifactory as its backend** (`backend "artifactory"` in the `.tf` files the job runs).
2. **The Jenkins job uploads to Artifactory**, for example by publishing a package, pushing an image or
   deploying a build artifact.

Everything else gets `ro`. Choose the scope for each call site, not for the whole job. In a job that
uses the Terraform backend, a separate `curl` download still gets `ro`. If a single script both
downloads and uploads, it gets `rw`.

| Credential use | Scope |
|---|---|
| Terraform `backend "artifactory"`: every backend command (`init`, `plan`, `apply`, `destroy`, `import`, `state *`) | **`rw`**. State is read and written on every run, so don't split it into RO for plan and RW for apply. |
| Upload or publish: `curl -X PUT`/`-T`, `jf rt upload`, `npm publish`, `docker push`, `mvn deploy`, `gradle publish`, `twine upload`, `helm push` | **`rw`** |
| Everything else, for example downloads: `curl` GET, `jf rt download`, `npm install`, `pip install`, `docker pull`, Terraform provider or module downloads with a non-Artifactory backend | `ro` |

If you can't tell whether a call site uploads, ask the user instead of choosing `rw` to be safe.
If you choose `rw`, say which of the two cases applies, both in the PR body and in the report. The
helper derives the token settings from the scope:

| | RO | RW |
|---|---|---|
| STS `--audience` | `DJ-Artifactory-RO` | `DJ-Artifactory-RW` |
| JFrog `provider_name` | `aws-iam-ro-<accountId>` | `aws-iam-rw-<accountId>` |
| Exchange endpoint | `https://artifactory.dowjones.io/access/api/v1/oidc/token` | same |

## What the helper block provides

| Function | Purpose |
|---|---|
| `shWithArtifactoryToken(scope, script)` | **Use this one.** Mints a token, runs `script` with `ARTIFACTORY_USERNAME`/`ARTIFACTORY_PASSWORD` set, prints the output with secrets replaced by `****`, and returns the exit code. It behaves like `sh(returnStatus: true, ...)`. |
| `getArtifactoryToken(scope)` | Returns `[username:, token:]`. Use it only if you really need the raw token, because masking it is then your job. |
| `shQuiet(envVars, script)` | Runs a one-line `sh` with no `set -x` and output that isn't logged, and returns the trimmed stdout. Secrets go in through `envVars`. |
| `jsonField(json, field)` | Regex lookup of one string field in a JSON response (`@NonCPS`). |

Behavior to tell the user about:

- **Output is buffered.** Each wrapped command's output appears when it finishes, not live. Very large
  `TF_LOG=TRACE` output is held in memory first.
- **Each call mints a fresh token.** Apply and destroy run after the approval `input`, so a long wait
  can't expire the token.
- **The token sits briefly in the build's program state** on the controller. That state is readable
  only by admins and is deleted when the build finishes. This has been accepted.

## Steps

1. **Create the branch.** From the repo's freshly pulled default branch, create
   `feature/oidc-artifactory-migration`:
   ```bash
   git checkout <default-branch> && git pull --ff-only && git checkout -b feature/oidc-artifactory-migration
   ```
2. **Take inventory** in the target repo:
   ```bash
   grep -n -E "withCredentials|credentialsId|UsernamePasswordMultiBinding|usernamePassword\(|string\(credentialsId|-backend-config=\"(username|password)|artifactory|@Library" Jenkinsfile
   grep -rn -A6 'backend "artifactory"' --include='*.tf' .
   ```
   If you find an `@Library(...)` shared library together with a `terraform(...)` step, stop and use
   the shared-library OIDC migration skill described above. Confirm the job targets the Dow Jones setup (the Dow Jones
   Artifactory host, an Artifactory credential bound with `credentialsId`, a Dow Jones Jenkins server).
   If it doesn't, stop and ask the user before going further.
3. **Classify each call site.** Choose `rw` only if it runs a Terraform command against an
   `artifactory` backend or uploads to Artifactory. Otherwise choose `ro` (see "Choosing the scope").
   Check the `.tf` files for the backend type rather than assuming it. Confirm the prerequisites,
   including that the node role is registered for every scope you chose.
4. **Paste the helper block.** Copy all of `scripts/artifactory-oidc-helpers.groovy`, including the
   `// BEGIN Artifactory` and `// END Artifactory` marker lines, which the verifier needs. Paste it as is,
   with no added comments. Put it after the existing helper functions and before the first function
   that uses it. No imports are needed.
5. **Rewrite each call site.** Remove the `withCredentials([...]) { }` wrapper and any
   `-backend-config="username=..."`/`"password=..."` flags, then run the script through the helper:
   ```groovy
   // before
   withCredentials([[$class: 'UsernamePasswordMultiBinding', credentialsId: '<artifactory-credential-id>',
                     usernameVariable: 'USERNAME', passwordVariable: 'PASSWORD']]) {
       def execInit = """
           cd ${dir}; yes yes 2>&1 | ${terraformBinary} init \
           -backend-config="username=${USERNAME}" -backend-config="password=${PASSWORD}" \
           -backend-config="subpath=${subpath}"
       """
       def exitCode = sh(returnStatus: true, script: execInit)
       ...
   }
   // after
   def execInit = """
       cd ${dir}; yes yes 2>&1 | ${terraformBinary} init \
       -backend-config="subpath=${subpath}"
   """
   def exitCode = shWithArtifactoryToken('rw', execInit)
   ...
   ```
   This example uses `rw` because the Terraform backend is Artifactory. A call site that only downloads,
   for example `curl -u "\$ARTIFACTORY_USERNAME:\$ARTIFACTORY_PASSWORD" -O <artifact-url>`, uses
   `shWithArtifactoryToken('ro', ...)`.
   - **Route every backend command through the helper** (`init`, `plan`, `apply plan.out`,
     `destroy`, `import.sh`, `terraform state ...`), not only `init`. A function may run `plan` more
     than once, for example a second run that captures output; route each one. `validate`, `fmt` and
     `--version` don't need a token.
   - **Never pass credentials as `-backend-config` username/password.** `plan -out` stores backend
     config, including credentials, in the plan file, and `init` writes it to
     `.terraform/terraform.tfstate`. The artifactory backend reads `ARTIFACTORY_USERNAME` and
     `ARTIFACTORY_PASSWORD` from the environment, so keep only `-backend-config="subpath=..."`.
   - **For non-Terraform uses**, reference the shell variables inside the script, escaped in a Groovy
     `"""` string: `curl -u "\$ARTIFACTORY_USERNAME:\$ARTIFACTORY_PASSWORD" ...` or
     `-H "Authorization: Bearer \$ARTIFACTORY_PASSWORD"`. Never interpolate `${creds.token}` into a script.
   - **Watch for variables declared twice.** If the method already declared the variable (for example
     `exitCode` earlier in `tfInit`), assign without `def`. A second `def` in the same method breaks the build.
   - **Leave commented-out call sites alone**, and mention them in the PR body so whoever re-enables
     them routes them through the helper.
6. **Verify offline.** Both checks must pass:
   ```bash
   <this skill dir>/scripts/verify-helpers.sh Jenkinsfile       # needs groovy, bash, jq
   grep -n -E "credentialsId|USERNAME\}|PASSWORD\}|withCredentials" Jenkinsfile   # expect no Artifactory hits
   ```
   The verifier checks that the Jenkinsfile parses and that the block has no calls needing script
   approval. It then runs the block with stubbed Jenkins steps and mocked `aws`/`curl`, and confirms
   that the token and Basic-auth form are masked, that exit codes come through, that both `ro` and `rw`
   mint a token with their own STS audience and JFrog provider, and that a failed
   exchange stops before the script runs. Look for `VERIFY: OK` in its output. This is not a Jenkins
   run, so say that when you report.
7. **Commit, push and open the PR.** Do this by default as soon as step 6 passes; don't stop to ask.
   Skip to step 8 without committing only if the user asked to review the changes before the PR, or
   if a step 6 check failed. Commit only the Jenkinsfile, never other uncommitted files in the
   working tree, following the session's commit attribution rules. Push the branch and open the PR
   against the default branch:
   ```bash
   git push -u origin feature/oidc-artifactory-migration
   gh pr create --base <default-branch> --head feature/oidc-artifactory-migration \
     --title "Replace static Artifactory credential with short-lived OIDC tokens" --body-file <body>
   ```
   - **If the SSH push fails** with `Permission denied (publickey)` and `gh` is logged in, push over
     HTTPS with gh's credentials without changing git config:
     `git -c credential.helper= -c credential.helper='!gh auth git-credential' push https://github.com/<org>/<repo>.git feature/oidc-artifactory-migration`
   - **PR body:** a summary, the call-site table (function, command, scope, reason for `rw`, change), the prerequisites (name
     the Jenkins node labels the job uses), the behavior changes and the testing done. Say plainly
     that the testing was offline and that no Jenkins run has happened yet. End it with the session's
     PR attribution line.
   - **Several repos:** write the body to a file outside the repos, adapt it per repo when the call
     sites differ, and open one PR per repo.
8. **Report.** Give the PR URL(s), each call site with its scope (and, for `rw`, which case applies), the credential removed, what was
   verified, the prerequisites and the behavior notes above. Recommend a `plan` run first, then one
   with `TF_LOG=DEBUG` to confirm masking. If the user asked to review first, report the uncommitted
   diff instead and open the PR when they approve.

## Troubleshooting a real run

| Symptom in the console | Cause and fix |
|---|---|
| `Scripts not permitted to use ...` | A call that needs approval was added to the block. Move that work into `shQuiet`; don't approve the signature. |
| `aws: error: argument operation: Invalid choice` for `get-web-identity-token` | The AWS CLI on the node is too old. Upgrade it. |
| `AccessDenied` from `GetWebIdentityToken` | The node role lacks `sts:GetWebIdentityToken`, or outbound web identity federation is off for the account (prerequisites 1 and 2). |
| `getArtifactoryToken: unexpected output from aws sts` | The STS call printed something other than a token. Run the same `aws sts` command on that node. |
| `No Artifactory 'rw' token returned: ...` | JFrog rejected the exchange. Usually the `aws-iam-<scope>-<accountId>` provider is missing or the role is not registered for that scope (prerequisite 3). |
| Terraform backend `401` or `403` | Wrong scope (use `rw` for state), or the username doesn't match the token's `sub`. Don't override `ARTIFACTORY_USERNAME`. |
| `403` on an upload or publish | The call site uses `ro`. Switch it to `rw` and make sure the node role is registered with the `aws-iam-rw-<accountId>` provider. |
