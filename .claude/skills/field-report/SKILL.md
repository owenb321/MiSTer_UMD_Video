---
name: field-report
description: Turn a field report — pasted text or a screenshot of a thread — into a tracked issue on the repository (gh on GitHub). Use when the user shares a user's bug report and wants it filed or tracked.
---

# Filing a field report as an issue

**The output is one thing: a drafted issue, shown for approval before anything is
created.** Do not draft replies to the reporter (memory: the maintainer writes to users in
their own voice); list what is missing under **Not stated** instead.

## Rules

- **Never invent a detail.** Everything not stated goes under **Not stated** — never
  guessed, never a default. A fabricated version line sends the maintainer to the wrong
  build and nobody notices.
- **Strip personal information.** No handles, names, servers, channels, paths from the
  reporter's machine. Attribution is exactly `_Reported via Discord, YYYY-MM-DD._`
- **Never attach a chat screenshot** (it publishes handles and other people's messages);
  transcribe. **Never guess an illegible character**: an ambiguous digit is Not stated.
- **Confirm before creating.** Filing is outward-facing. Show the full body and wait.
- **Check for duplicates first.**

## Classify (labels mirror `.github/ISSUE_TEMPLATE/`)

| about | label |
|---|---|
| playlist, chapters, wrong title, seek | `area:navigation` |
| a silent or wrong track | `area:audio` |
| nothing loads, black screen, `UNSUPPORTED IMAGE` | `area:loading` |
| stutter, artefacts, lip sync, subtitles | `area:playback` |
| analog / CRT picture, sync, geometry | `area:analog` |

Always add `bug` (or `enhancement` instead, for a request).

## Body

```markdown
_Reported via Discord, 2026-09-22._

### What was reported
<the report in the reporter's own terms, tidied for spelling only>

### Details given
| | |
|---|---|
| Core version | `dev-scaffold 260922` |
| Image | <title>, how made |

### Not stated
- Core version
- Whether it worked in an earlier version
```

## Create

- `gh issue create --repo owenb321/MiSTer_UMD_Video --title ... --label bug --label area:navigation --body-file /tmp/issue_body.md`

Write the body to a file, never inline. Titles: concrete and searchable. If a label does
not exist yet, create it once. Hand back the issue URL and nothing else.
