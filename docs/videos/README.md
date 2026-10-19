# Deploy videos

Short chapters (2 to 5 minutes) that walk a customer through deploying
HailBytes SAT and ASM with this repository. There is one series per cloud,
because each marketplace rejects media that names the other cloud.

| Cloud | Chapters | Script | ASM cut |
|---|---|---|---|
| Azure | 1 Marketplace terms and programmatic deployment · 2 The deploying identity · 3 Deploy · 4 Entra ID · 5 Tear down | [azure/SCRIPT.md](azure/SCRIPT.md) | [azure/ASM.md](azure/ASM.md) |
| AWS | 1 Subscribe and run the preflight · 2 Deploy · 3 DNS, a certificate and operator access · 4 Tear down | [aws/SCRIPT.md](aws/SCRIPT.md) | [aws/ASM.md](aws/ASM.md) |

The SAT chapters for both clouds have specs and render today. The ASM cuts are
written up as the changes from SAT; their specs are copies with those edits.

## Layout

```
docs/videos/
  specs/<cloud>-<product>-<NN>-<slug>.yaml   one chapter: cards, terminal steps, captions
  render/render_video.py                     spec -> .mp4 + .srt + .cast (and --preview, --script)
  render/assets/                             Inter (OFL) and the HailBytes mark
  azure/SCRIPT.md, aws/SCRIPT.md             generated from the specs; edit the specs
  azure/ASM.md, aws/ASM.md                   what the ASM cut changes
  out/                                       render output (gitignored)
```

## Render

Needs Python with `pyyaml` and `playwright` (`playwright install chromium`, or
pass `--channel chrome`) and `ffmpeg` on `PATH`. No cloud credentials, and
nothing is deployed.

```bash
python docs/videos/render/render_video.py docs/videos/specs/azure-sat-*.yaml          # videos into docs/videos/out/
python docs/videos/render/render_video.py docs/videos/specs/azure-sat-03-deploy.yaml --preview   # one PNG per step
python docs/videos/render/render_video.py docs/videos/specs/azure-sat-*.yaml --script docs/videos/azure/SCRIPT.md
python docs/videos/render/render_video.py docs/videos/specs/*.yaml --lint-only
```

Each chapter renders in about two minutes. Per chapter you get:

- `<id>.mp4`: 1920x1080, 30 fps, captions burned in, so it plays silently in a
  listing or a help centre.
- `<id>.srt`: the same captions as a sidecar track, and the narration script for
  a voiced cut.
- `<id>.cast`: the terminal steps as an asciinema recording, for an embeddable
  player or `agg` to GIF.

Add `--music <file>` for a quiet bed under the captions. A narrated cut of
`azure-sat-03-deploy` (TTS voice, annotated screenshots) is produced from the
same spec in hailbytes-sat `scripts/marketing/deploy-videos/`.

## Rules for every spec

1. **One cloud per video.** An Azure spec never names AWS, and an AWS spec never
   names Azure or Microsoft (Entra, Cloud Shell, `az`). The renderer refuses a
   spec that does: run `--lint-only` before committing. Add your own words with
   `--deny-file <path>`, a file kept outside the repository.
2. **Terminal output is sample output, and says so.** It is reconstructed from
   the scripts' own `echo` lines, and every terminal frame carries a SAMPLE
   OUTPUT badge. Counts and elapsed times are illustrative; the elapsed times
   match what real deployments took. If a script's output changes, update the
   spec.
3. **Placeholders only.** Subscription "HailBytes Demo", IDs
   `00000000-...`, `11111111-...` (groups), account `123456789012`, user
   `admin@example.com`, client `acme`, addresses from the documentation ranges
   (`203.0.113.0/24`, `198.51.100.0/24`), hostname `sat.example.com`. Secrets
   are masked as `****`. Never a real tenant, account, customer or secret.
4. **Only what the product does today.** No ASM single sign-on (ASM stores the
   settings but has no sign-in flow). No SCIM from Entra ID into ASM (its SCIM
   endpoint takes `X-API-Key`, which Entra cannot send).
5. **Captions are the narration.** Lines run at about 2.3 words a second, and a
   caption stays up until it has been on screen for its reading time.

## Recording a real deployment instead

The terminal steps can be replaced with a real recording
(`asciinema rec`, then the `.cast` in place of the scripted session), but a
real apply creates billable resources in a real subscription or account.
Agree the subscription and the budget first, record `plan` and the preflight
before any `apply`, and destroy afterwards (chapter 5 / chapter 4).

## Spec format

```yaml
id: azure-sat-03-deploy
cloud: azure                 # azure | aws
product: sat                 # sat | asm
chapter: 3
title: Deploy HailBytes SAT on Azure
steps:
  - type: title | card       # eyebrow, headline, sub, bullets (`code` in backticks), narration, hold
  - type: terminal           # sample: true (default), title, hold
    session:
      - say: Caption shown until the next say
      - cmd: typed at the prompt
      - out: |               # printed a line at a time; {g}{y}{r}{c}{b}{d} colour, {/} reset
      - ask: "Prompt text: " # a prompt that waits on the same line...
      - input: "1"           # ...for this answer
      - pause: 1.5
      - clear: true
```

A `callout` step (annotated screenshot) belongs to the narrated cut. This
renderer draws it as a card with the callout labels.
