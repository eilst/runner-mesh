# GitHub App setup

`runner-mesh` authenticates to GitHub as a **GitHub App**, not a personal
access token — scoped permissions, not tied to your personal account, and
revocable independently of anything else you use that account for.

## What `app:init` does for you

```bash
runner-mesh app:init
```

1. Builds an App manifest (name, permissions: `actions:write`,
   `administration:write`, `checks:read`, `metadata:read`; no webhook
   events subscribed — the scale-set listener polls, it doesn't need
   inbound webhooks).
2. Opens your browser to GitHub's App-creation confirmation page, manifest
   pre-filled. **This is the one manual step in the entire flow** — GitHub
   requires an explicit human click to create an App; there is no API to
   skip it.
3. Catches GitHub's redirect on a throwaway local server
   (`127.0.0.1:8934`) and exchanges the one-time code for real App
   credentials — no copy-pasting tokens.
4. Saves credentials to `~/.config/runner-mesh/github-app.json`, mode
   `0600`, **outside this repository** so there is no risk of ever
   committing them.

## What you do after `app:init`

The App exists but has access to zero repos until you install it. Open the
URL printed at the end of `app:init` (`https://github.com/apps/<slug>/installations/new`)
and pick "Only select repositories" — choose whichever repos you want
runners for. This installation screen is GitHub's own native UI; it's the
actual authorization boundary, and you can revisit it anytime under
**Settings → Applications → [your App] → Configure** to add or remove
repos without ever touching `runner-mesh` or your cluster.

Then:

```bash
runner-mesh repos:list      # see what the App can now see
runner-mesh repos:add       # interactively pick which of those get runners
```

## Why this works without a GitHub org

GitHub's own **org-level runners** (register once, share across every repo
in the org, controlled by runner groups) are the "correct" GitHub-native
way to share runners across repos — but they only exist for
organizations. There is no equivalent for a personal account; runners
there are strictly repo-scoped, one registration per repo, full stop.

GitHub Apps don't have that restriction. You can create an App under your
**personal** account and install it on any repos your personal account
owns — the installation step (`https://github.com/apps/<slug>/installations/new`)
works identically whether the App and repos belong to an org or to you
personally. That's the actual reason `runner-mesh` is built on the App
model instead of org runner groups: it's the one mechanism that gives you
"one credential, many repos" sharing *without* requiring you to have (or
create) an org at all. If your repos are personal, nothing in this setup
changes — same `app:init`, same installation screen, same `repos:add`.

## Why not a Personal Access Token?

A PAT is simpler to wire up, but ties every scale-set's access to your
personal account — if you rotate or revoke that token for unrelated
reasons, every repo's runners break at once, and a PAT's permission scopes
are coarser than an App's. `runner-mesh` doesn't currently ship a
PAT-based path; open an issue if that's a hard requirement for your setup.

## Rotating credentials

Re-run `runner-mesh app:init` — it detects the existing config and, after
confirmation, walks the manifest flow again for a fresh App. Existing
per-repo secrets are updated the next time you run `repos:add <repo>` for
each one (this is not yet automated across every provisioned repo in one
step — see `docs/roadmap.md`).
