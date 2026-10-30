# claude-skills

A Claude Code plugin marketplace of internal skills for Dow Jones infrastructure
and platform engineering work. Each top-level folder is one plugin; each plugin
folder's own `README.md` documents what it does.

## Plugins in this repo

| Plugin | What it does |
|---|---|
| [`migrate-secrets-oidc`](migrate-secrets-oidc/README.md) | Migrates a CommonInstaller-based deploy project off plaintext/Terraform-resolved secrets and static Artifactory credentials onto runtime Secrets Manager fetch + OIDC Artifactory auth, and cleans up Jenkinsfile credential usage more generally. |

## How to install the skills in Claude Code

Add this repo as a plugin marketplace once, then install whichever plugin(s)
you need. This works from a terminal session, the desktop app, or the VS Code
extension.

**1. Add the marketplace** (one-time, per machine):

```
/plugin marketplace add newscorp-djcs/claude-skills
```

Or from a shell, without starting a session:

```bash
claude plugin marketplace add newscorp-djcs/claude-skills
```

**2. Install a plugin:**

```
/plugin install migrate-secrets-oidc@claude-skills
```

Or from a shell:

```bash
claude plugin install migrate-secrets-oidc@claude-skills
```

You'll be asked to pick a scope — user (every project on this machine),
project (shared with collaborators via `.claude/settings.json`), or local
(this repo only, just for you). User scope is the usual choice for these
skills.

**3. Confirm it loaded:** type `/` in a session and look for
`/migrate-secrets-oidc:migrate-secrets-oidc`, or run `claude plugin list`.

To add a new plugin later, add its folder under this repo root with its own
`.claude-plugin/plugin.json` (or a bare `SKILL.md` at the folder root), then
add an entry for it to `.claude-plugin/marketplace.json`'s `plugins` array.
Anyone who already added this marketplace picks up the new plugin the next
time they run `/plugin marketplace update claude-skills` (or on its next
auto-refresh) — no need to re-add the marketplace.

### Updating a plugin after a push

```
/plugin marketplace update claude-skills
```

This refreshes the catalog and updates any plugin from it you've already
installed.
