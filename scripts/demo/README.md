# Recording the README demo GIF

The demo shows the money moment: a job queues, a runner pod is born, the
job goes green, the pod vanishes. ~20 seconds, recorded with
[vhs](https://github.com/charmbracelet/vhs) (`brew install vhs`).

## Pre-flight

1. A provisioned pool with a healthy listener (`runner-mesh status`).
2. A workflow in the target repo with `runs-on: <pool-name>` and a short
   job (~30–60s; a lint job is ideal).
3. Terminal at 120×30, no personal info in the prompt.

## Recording

Because the pod lifecycle is driven by a real GitHub job, the recording
is a two-terminal choreography rather than a fully-scripted tape:

1. Terminal A (the one being recorded): `vhs record > demo.tape`, then
   run, with natural pauses:
   ```bash
   runner-mesh status
   kubectl get pods -n arc-runners --watch
   ```
2. Terminal B (off-screen): trigger the job —
   `gh workflow run <workflow> --repo <owner/repo>` (or push a commit).
3. Let the watch show: pod appears (Init → Running) → job executes →
   pod terminates. Stop the watch, run `runner-mesh status` once more
   (back to `active_runners=0`).
4. Trim the tape's dead air, add the standard header, render:
   ```bash
   vhs demo.tape   # emits demo.gif per the Output directive
   ```

## Tape header (paste at the top of the recorded tape)

```
Output docs/assets/demo.gif
Set FontSize 15
Set Width 1200
Set Height 640
Set Theme "Catppuccin Mocha"
Set TypingSpeed 40ms
```

Commit the GIF to `docs/assets/demo.gif` and reference it at the very top
of the README, right under the tagline.
