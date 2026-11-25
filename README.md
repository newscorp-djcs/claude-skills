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

This only registers the catalog — no skill is installed or usable yet. If
you run `/reload-plugins` right now, `0 plugins` is the correct result, not
an error; you still need step 2 below.

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
skills, and it's also the default when running non-interactively (no TTY,
e.g. scripted installs), so a scriptable call doesn't need `-s user` unless
you want a different scope.

Tip: from a shell, you can skip step 1 entirely and do both steps in one
command — `--marketplace` adds the marketplace first if it isn't already
known:

```bash
claude plugin install migrate-secrets-oidc --marketplace newscorp-djcs/claude-skills
```

**3. Confirm it loaded:** type `/` in a session and look for
`/migrate-secrets-oidc:migrate-secrets-oidc`, or run `claude plugin list`.

### Troubleshooting

**"I added the marketplace and ran `/reload-plugins` but nothing shows
up."** This is expected, not a bug: `/plugin marketplace add` only
registers the catalog of available plugins, it doesn't install any of
them. `/reload-plugins` reloads whatever is already enabled — with nothing
installed yet, there's nothing for it to find. Run step 2
(`/plugin install migrate-secrets-oidc@claude-skills`) to actually install
the plugin, then `/reload-plugins` will have something to pick up.

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
installed. Then start a new session or run `/reload-plugins`. If a plugin still
shows its old version, run `/plugin update <plugin>@claude-skills`, or
uninstall and reinstall it.

**Maintainers: bump `version` on every change users should receive.** Claude
Code decides whether an installed plugin is out of date from the `version` in
`<plugin>/.claude-plugin/plugin.json`. If you change a plugin's files but leave
the version alone, people who already installed it can be told they're up to
date and keep running the cached copy. Use a minor bump (`1.0.0` → `1.1.0`)
for new capability, a patch bump (`1.1.0` → `1.1.1`) for wording fixes. Merging
to `main` is the publish step; there are no tags or CI to run.
