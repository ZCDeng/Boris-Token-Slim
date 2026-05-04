# Security Policy

## Promise: never `rm -rf` your data

Boris-Token-Slim mutates files inside `~/.claude/`. Every action that removes content from your active config goes through one channel:

```bash
mv <source> ~/.claude/_tokenslim_archive_<YYYYMMDD>/<category>/
```

You can `mv` it back if you regret the choice. Search the codebase for `rm -rf` — there is none in `scripts/`. The only `rm` calls are:

- `scripts/archive-helper.sh clean-dead`: removes broken symlinks (the targets don't exist; nothing is destroyed)

If you ever see a PR that adds `rm -rf` to user-facing scripts, **block it**.

## Reporting a vulnerability

Open a GitHub issue with `[security]` in the title at https://github.com/ZCDeng/Boris-Token-Slim/issues/new — the maintainer monitors this repo's issues.

For sensitive disclosures that shouldn't be public, GitHub Security Advisories work too: https://github.com/ZCDeng/Boris-Token-Slim/security/advisories/new — these are private until you choose to publish.

What counts as a security issue here:

- Path injection allowing the script to operate outside `~/.claude/`
- Eval-style code execution via crafted plugin manifest, transcript JSONL, or filename
- Any code path that could `rm`, `truncate`, or otherwise destroy user data without explicit `mv`-to-archive
- Credential leakage (the scripts read `~/.claude.json` which contains tokens — they should never log token values)

What's **not** a security issue:

- "audit.sh said my plugin count is too high" — that's the tool working as designed
- "MCP zombie resurrection happens after I uninstall" — that's a Claude Code behavior we report on, not introduce

## Threat model

Boris-Token-Slim runs locally with the user's permissions. It assumes:

- The user owns `~/.claude/` and trusts its contents
- `~/.claude.json` and plugin manifests are not adversarial
- Network is untrusted (we make no network calls)

If you have an adversarial multi-tenant setup (shared `~/.claude/`), this tool is not designed for that. Run it in a single-user container instead.

## What the scripts read

For full transparency:

| Script | Reads | Writes |
|---|---|---|
| `scripts/audit.sh` | `~/.claude/CLAUDE.md`, `~/.claude/projects/<encoded-home>/memory/MEMORY.md`, `~/.claude/plugins/installed_plugins.json`, `~/.claude/plugins/cache/*/plugin.json`, `~/.claude.json`, `~/.claude/settings*.json`, `~/.claude/skills/*` (lstat only) | Nothing. Prints to stdout. |
| `scripts/analyze.py` | `~/.claude/projects/**/*.jsonl` (transcripts) | Nothing in default mode. `--json` writes to stdout. |
| `scripts/archive-helper.sh` | The above as needed | `mv` operations into `~/.claude/_tokenslim_archive_*/`. Plus `rm` of broken symlinks (which point nowhere) when `clean-dead` is invoked. |

## What the scripts never do

- Send data over the network
- Modify `~/.claude.json`, `installed_plugins.json`, or any settings file
- Call `rm` on anything other than broken symlinks (in `archive-helper.sh clean-dead`)
- Execute code from plugin manifests or transcript content
- Bypass branch protection or CI gates on this repo

## Audit before you run

Don't trust this README. Read the scripts:

```bash
wc -l scripts/*.sh scripts/*.py
grep -nE 'rm|unlink|shutil.rmtree|os.remove|truncate' scripts/*.sh scripts/*.py
```

Should show only:

- `clean-dead` action in `archive-helper.sh` (broken symlinks)
- (No matches in `audit.sh` or `analyze.py`)
