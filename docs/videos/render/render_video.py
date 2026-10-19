"""Render a deploy-video chapter from its YAML spec.

    python docs/videos/render/render_video.py docs/videos/specs/azure-sat-03-deploy.yaml

writes, per spec, into --out (default docs/videos/out/, gitignored):

    <id>.mp4    1920x1080, 30 fps, captions burned in
    <id>.srt    the same captions as a sidecar subtitle track
    <id>.cast   the terminal segments as an asciinema v2 recording

Every frame is HTML rendered by Playwright (Inter, navy #182851, teal #35B3C8:
the look of the marketplace store assets), so a chapter re-renders exactly
from its spec. Terminal segments are scripted, not screen-recorded: a `cmd` is
typed, its `out` printed a line at a time, and the segment carries a SAMPLE
OUTPUT badge unless `sample: false`. Frames are only taken when the picture
changes; ffmpeg's concat demuxer holds each one for its duration.

Before rendering, every spec is linted: a chapter for one cloud must not name
the other, because each marketplace rejects media that does. `--lint-only`
runs just that, and `--deny-file` adds words of your own (one per line, kept
outside the repo) that no spec may contain.

Needs: pyyaml, playwright (Chromium, or --channel chrome), ffmpeg on PATH.
"""

import argparse
import base64
import html
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml
from playwright.sync_api import sync_playwright

HERE = Path(__file__).resolve().parent
FONT = HERE / "assets/inter-latin-wght-normal.woff2"
LOGO = HERE / "assets/hailbytes-logo-light.png"

W, H, FPS = 1920, 1080, 30
TYPE_CPS = 28          # typing speed for `cmd` and `input`
LINE_SECONDS = 0.035   # per printed output line
WPS = 2.6              # caption reading speed, words per second
COLS, ROWS = 115, 21   # terminal grid at 24px Cascadia Mono, also the .cast size

PRODUCTS = {"sat": "HailBytes SAT", "asm": "HailBytes ASM"}
SHELL_TITLE = {"azure": "Azure Cloud Shell (Bash)", "aws": "CloudShell (bash)"}

# Each marketplace rejects media that names the other cloud.
FORBIDDEN = {
    "azure": r"\bAWS\b|\bAmazon\b|\bEC2\b|CloudShell|\bS3\b|\bRDS\b|\bALB\b|\bSSM\b|\bACM\b",
    "aws": r"Azure|Microsoft|\bEntra\b|Cloud Shell|\bARM_[A-Z_]+|\baz \w",
}

TAGS = {"g": "#4ade80", "y": "#facc15", "r": "#f87171", "c": "#5fd7e8"}
ANSI = {"g": "\x1b[32m", "y": "\x1b[33m", "r": "\x1b[31m", "c": "\x1b[36m",
        "b": "\x1b[1m", "d": "\x1b[2m", "/": "\x1b[0m"}
TAG_RE = re.compile(r"\{([gyrcbd/])\}")


def data_uri(path: Path, mime: str) -> str:
    return f"data:{mime};base64,{base64.b64encode(path.read_bytes()).decode()}"


def strip_tags(text: str) -> str:
    return TAG_RE.sub("", text)


def tags_to_html(text: str) -> str:
    out, open_spans = [], 0
    for i, part in enumerate(TAG_RE.split(text)):
        if i % 2 == 0:
            out.append(html.escape(part))
        elif part == "/":
            out.append("</span>" * open_spans)
            open_spans = 0
        else:
            style = {"b": "font-weight:700", "d": "opacity:.55"}.get(part, f"color:{TAGS.get(part)}")
            out.append(f"<span style='{style}'>")
            open_spans += 1
    return "".join(out) + "</span>" * open_spans


def tags_to_ansi(text: str) -> str:
    return TAG_RE.sub(lambda m: ANSI[m.group(1)], text)


def screen_tail(lines: list) -> list:
    """The last lines that fit ROWS screen rows, counting the rows a long line wraps to."""
    kept, rows = [], 0
    for line in reversed(lines):
        rows += max(1, -(-len(strip_tags(line)) // COLS))
        if rows > ROWS:
            break
        kept.append(line)
    return kept[::-1]


def read_seconds(text: str) -> float:
    return len(strip_tags(text or "").split()) / WPS + 1.2


# ---------------------------------------------------------------- lint

def spec_text(node) -> str:
    if isinstance(node, dict):
        return "\n".join(spec_text(v) for v in node.values())
    if isinstance(node, list):
        return "\n".join(spec_text(v) for v in node)
    return str(node) if node is not None else ""


def lint(spec: dict, path: Path, deny: list) -> list:
    errors = []
    cloud, product = spec.get("cloud"), spec.get("product")
    if cloud not in FORBIDDEN:
        errors.append(f"{path.name}: cloud must be one of {sorted(FORBIDDEN)}")
    if product not in PRODUCTS:
        errors.append(f"{path.name}: product must be one of {sorted(PRODUCTS)}")
    text = spec_text({k: v for k, v in spec.items() if k not in ("cloud", "product")})
    if cloud in FORBIDDEN:
        for m in re.finditer(FORBIDDEN[cloud], text):
            line = text[:m.start()].count("\n") + 1
            errors.append(f"{path.name}: names another cloud ('{m.group(0)}', text line {line})")
    for word in deny:
        if re.search(re.escape(word), text, re.I):
            errors.append(f"{path.name}: contains a denied word from --deny-file")
    for i, step in enumerate(spec.get("steps", [])):
        if step.get("type") not in ("title", "card", "terminal", "callout"):
            errors.append(f"{path.name}: step {i + 1} has unknown type {step.get('type')!r}")
    return errors


# ---------------------------------------------------------------- timeline
# A timeline is a list of [state, seconds]. A state is a plain dict the page
# script draws; identical neighbours are merged so they cost one screenshot.

class Timeline:
    def __init__(self):
        self.frames = []       # [state, seconds]
        self.captions = []     # [start, end, text]
        self.cast = []         # [t, data] relative to the cast clock
        self.cast_clock = 0.0
        self.t = 0.0
        self.step_ends = []    # frame index that closes each step, for --preview

    def add(self, state: dict, seconds: float):
        if seconds <= 0:
            return
        if self.frames and self.frames[-1][0] == state:
            self.frames[-1][1] += seconds
        else:
            self.frames.append([state, seconds])
        self.t += seconds

    def caption(self, text: str, start: float, end: float):
        if text:
            self.captions.append([start, end, strip_tags(text)])


def card_state(spec: dict, step: dict, kind: str) -> dict:
    return {"kind": kind, "eyebrow": step.get("eyebrow", ""), "headline": step.get("headline", ""),
            "sub": step.get("sub", ""), "bullets": step.get("bullets", []),
            "caption": strip_tags(step.get("narration", "")), "chapter": chapter_tag(spec),
            "product": PRODUCTS[spec["product"]]}


def chapter_tag(spec: dict) -> str:
    return f"Chapter {spec['chapter']} · {spec['title']}" if spec.get("chapter") else spec["title"]


def add_card(tl: Timeline, spec: dict, step: dict):
    kind = step["type"] if step["type"] in ("title", "card") else "card"
    if step["type"] == "callout":   # rendered stills belong to the narrated cut
        step = {"eyebrow": "On screen", "headline": step.get("headline", ""),
                "bullets": [c.get("label", "") for c in step.get("callouts", [])], **step}
    words = " ".join([step.get("headline", ""), step.get("sub", "")] + step.get("bullets", []))
    seconds = step.get("hold") or max(4.0, read_seconds(step.get("narration", "")),
                                      len(words.split()) / 3.2 + 1.5)
    start = tl.t
    tl.add(card_state(spec, step, kind), seconds)
    tl.caption(step.get("narration", ""), start, tl.t)


def add_terminal(tl: Timeline, spec: dict, step: dict):
    prompt = step.get("prompt", "$ ")
    sample = step.get("sample", True)
    lines = []                 # rendered lines (with colour tags)
    caption, caption_start = "", tl.t

    def state(partial=None, cursor=True):
        shown = lines + ([partial] if partial is not None else [])
        return {"kind": "terminal", "lines": screen_tail(shown), "cursor": cursor,
                "caption": strip_tags(caption), "sample": sample,
                "title": step.get("title", SHELL_TITLE[spec["cloud"]]),
                "chapter": chapter_tag(spec), "product": PRODUCTS[spec["product"]]}

    def emit(data: str, seconds: float, st: dict):
        tl.cast.append([round(tl.cast_clock, 3), data])
        tl.cast_clock += seconds
        tl.add(st, seconds)

    def close_caption():
        nonlocal caption
        if caption:
            short = read_seconds(caption) - (tl.t - caption_start)
            if short > 0:
                tl.add(state(), short)
                tl.cast_clock += short
            tl.caption(caption, caption_start, tl.t)

    def type_text(lead: str, text: str):
        plain = strip_tags(text)
        for n in range(0, len(plain) + 1, 2):
            emit(plain[n:n + 2], 2 / TYPE_CPS, state(lead + plain[:n]))
        lines.append(lead + text)
        emit("\r\n", 0.25, state())

    lines.append("")
    for item in step["session"]:
        if "say" in item:
            close_caption()
            caption, caption_start = item["say"], tl.t
            tl.add(state(), 0.4)
            tl.cast_clock += 0.4
        elif "cmd" in item:
            emit(tags_to_ansi("{g}" + prompt + "{/}"), 0.35, state("{g}" + prompt + "{/}"))
            type_text("{g}" + prompt + "{/}", item["cmd"])
        elif "input" in item:
            lead = lines.pop() if lines else ""
            type_text(lead, item["input"])
        elif "out" in item:
            for raw in str(item["out"]).rstrip("\n").split("\n"):
                lines.append(raw)
                emit(tags_to_ansi(raw) + "\r\n", LINE_SECONDS, state(cursor=False))
            tl.add(state(cursor=False), 0.6)
            tl.cast_clock += 0.6
        elif "ask" in item:   # a prompt that waits on the same line for `input`
            lines.append(item["ask"])
            emit(tags_to_ansi(item["ask"]), 0.8, state())
        elif "pause" in item:
            tl.add(state(), float(item["pause"]))
            tl.cast_clock += float(item["pause"])
        elif "clear" in item:
            lines.clear()
            lines.append("")
            emit("\x1b[2J\x1b[H", 0.2, state())
    close_caption()
    tl.add(state(), step.get("hold", 1.5))
    tl.cast_clock += step.get("hold", 1.5)


def build_timeline(spec: dict) -> Timeline:
    tl = Timeline()
    for step in spec["steps"]:
        if step["type"] == "terminal":
            add_terminal(tl, spec, step)
        else:
            add_card(tl, spec, step)
        tl.step_ends.append(len(tl.frames) - 1)
    return tl


# ---------------------------------------------------------------- page

PAGE_CSS = """
@font-face { font-family: Inter; src: url('%(font)s') format('woff2'); font-weight: 100 900; }
* { box-sizing: border-box; margin: 0; padding: 0; }
html, body { width: 1920px; height: 1080px; overflow: hidden; }
body { font-family: Inter, 'Segoe UI', sans-serif; color: #fff; position: relative;
  background:
    radial-gradient(1200px 700px at 85%% -10%%, rgba(53,179,200,.30), transparent 60%%),
    radial-gradient(900px 600px at -10%% 110%%, rgba(53,179,200,.14), transparent 60%%),
    linear-gradient(160deg, #0b1430 0%%, #182851 55%%, #0e1a3d 100%%); }
body::before { content: ''; position: absolute; inset: 0; opacity: .07;
  background-image: linear-gradient(#fff 1px, transparent 1px),
                    linear-gradient(90deg, #fff 1px, transparent 1px);
  background-size: 64px 64px; mask-image: linear-gradient(180deg, #000, transparent 70%%); }
.brand { position: absolute; top: 40px; left: 96px; display: flex; align-items: center; gap: 14px;
         font-weight: 650; font-size: 26px; color: #dbe6ff; }
.brand img { width: 44px; height: 44px; }
.chap { position: absolute; top: 52px; right: 96px; font-size: 20px; color: #8ea0c6; }
.copy { position: absolute; top: 200px; left: 96px; width: 1728px; }
.eyebrow { color: #35B3C8; font-weight: 700; font-size: 24px; letter-spacing: 3px;
           text-transform: uppercase; margin-bottom: 18px; }
h1 { font-size: 68px; line-height: 1.07; font-weight: 780; letter-spacing: -1.2px; max-width: 1600px; }
.sub { margin-top: 22px; font-size: 32px; line-height: 1.4; color: #c9d5ee; max-width: 1400px; }
ul { margin-top: 40px; list-style: none; max-width: 1560px; }
li { font-size: 34px; line-height: 1.35; color: #e6eefc; padding: 12px 0 12px 46px; position: relative; }
li::before { content: ''; position: absolute; left: 4px; top: 27px; width: 16px; height: 16px;
             border-radius: 4px; background: #35B3C8; }
li code, .sub code, h1 code { font-family: 'Cascadia Mono', 'DejaVu Sans Mono', monospace; font-size: .86em;
          background: rgba(53,179,200,.14); border: 1px solid rgba(53,179,200,.35);
          border-radius: 8px; padding: 1px 10px; color: #dff7fb; }
body.title .copy { top: 300px; width: 1180px; }
body.title h1 { font-size: 84px; }
.mark { position: absolute; right: 140px; top: 270px; width: 480px; height: 480px;
        filter: drop-shadow(0 0 60px rgba(53,179,200,.45)); display: none; }
body.title .mark { display: block; }
.term { position: absolute; left: 96px; top: 112px; width: 1728px; height: 776px; border-radius: 16px;
        overflow: hidden; background: #0b0f17; display: none;
        box-shadow: 0 40px 90px rgba(0,0,0,.55), 0 0 0 1px rgba(255,255,255,.10); }
body.terminal .term { display: block; }
body.terminal .copy, body.terminal .mark { display: none; }
.bar { height: 46px; background: #1d2433; display: flex; align-items: center; gap: 10px; padding: 0 18px;
       font-size: 19px; color: #9fb0d0; }
.bar i { width: 13px; height: 13px; border-radius: 50%%; background: #3b4458; display: block; }
.bar .t { margin-left: 14px; }
.badge { margin-left: auto; font-weight: 700; font-size: 16px; letter-spacing: 2px; color: #35B3C8;
         border: 1.5px solid rgba(53,179,200,.7); border-radius: 999px; padding: 4px 14px; }
pre { font-family: 'Cascadia Mono', 'DejaVu Sans Mono', 'Liberation Mono', monospace; font-size: 24px;
      line-height: 31.5px; color: #e5e7eb; padding: 22px 28px; height: 730px; overflow: hidden;
      }
pre div { white-space: pre-wrap; word-break: break-all; }
.cur { display: inline-block; width: 13px; height: 26px; background: #e5e7eb; vertical-align: -4px; }
.cap { position: absolute; left: 96px; right: 96px; bottom: 40px; min-height: 120px; display: none;
       align-items: center; padding: 18px 34px; border-radius: 14px; font-size: 31px; line-height: 1.38;
       color: #f4f7ff; background: rgba(8,14,34,.82); border: 1px solid rgba(53,179,200,.35); }
body.has-cap .cap { display: flex; }
"""

PAGE_JS = """
(s) => {
  const esc = t => t.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  const code = t => esc(t).replace(/`([^`]+)`/g, '<code>$1</code>');
  document.body.className = s.kind + (s.caption ? ' has-cap' : '');
  document.querySelector('.brand span').textContent = s.product;
  document.querySelector('.chap').textContent = s.chapter;
  document.querySelector('.cap').textContent = s.caption || '';
  if (s.kind === 'terminal') {
    document.querySelector('.bar .t').textContent = s.title;
    document.querySelector('.badge').style.display = s.sample ? '' : 'none';
    document.querySelector('pre div').innerHTML = s.lines.join('\\n') + (s.cursor ? "<span class='cur'></span>" : '');
  } else {
    document.querySelector('.eyebrow').textContent = s.eyebrow;
    document.querySelector('h1').innerHTML = code(s.headline);
    document.querySelector('.sub').innerHTML = code(s.sub || '');
    document.querySelector('ul').innerHTML = (s.bullets || []).map(b => '<li>' + code(b) + '</li>').join('');
  }
}
"""


def page_html() -> str:
    css = PAGE_CSS % {"font": data_uri(FONT, "font/woff2")}
    logo = data_uri(LOGO, "image/png")
    return (f"<!doctype html><html><head><meta charset='utf-8'><style>{css}</style></head><body>"
            f"<div class='brand'><img src='{logo}'><span></span></div><div class='chap'></div>"
            f"<div class='copy'><div class='eyebrow'></div><h1></h1><div class='sub'></div><ul></ul></div>"
            f"<img class='mark' src='{logo}'>"
            f"<div class='term'><div class='bar'><i></i><i></i><i></i><span class='t'></span>"
            f"<span class='badge'>SAMPLE OUTPUT</span></div><pre><div></div></pre></div>"
            f"<div class='cap'></div></body></html>")


def html_state(state: dict) -> dict:
    """Colour tags become spans only at draw time, so the timeline stays plain."""
    if state["kind"] != "terminal":
        return state
    return {**state, "lines": [tags_to_html(l) for l in state["lines"]]}


# ---------------------------------------------------------------- outputs

def srt_time(t: float) -> str:
    ms = int(round(t * 1000))
    return f"{ms // 3600000:02}:{ms // 60000 % 60:02}:{ms // 1000 % 60:02},{ms % 1000:03}"


def write_srt(captions: list, dest: Path):
    blocks = [f"{i}\n{srt_time(a)} --> {srt_time(b)}\n{text}\n"
              for i, (a, b, text) in enumerate(captions, 1)]
    dest.write_text("\n".join(blocks), encoding="utf-8")


def write_cast(tl: Timeline, spec: dict, dest: Path):
    header = {"version": 2, "width": COLS, "height": ROWS,
              "title": f"{PRODUCTS[spec['product']]}: {spec['title']} (sample output)"}
    rows = [json.dumps(header)] + [json.dumps([t, "o", d]) for t, d in tl.cast]
    dest.write_text("\n".join(rows) + "\n", encoding="utf-8")


def render_preview(spec: dict, out: Path, channel):
    """One PNG per step (its closing frame), for reviewing a spec without a render."""
    tl = build_timeline(spec)
    out.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as pw:
        browser = pw.chromium.launch(channel=channel, headless=True)
        page = browser.new_page(viewport={"width": W, "height": H})
        page.set_content(page_html(), wait_until="load")
        page.evaluate("document.fonts.ready")
        for n, i in enumerate(tl.step_ends, 1):
            page.evaluate(PAGE_JS, html_state(tl.frames[i][0]))
            page.screenshot(path=str(out / f"{spec['id']}-step{n:02}.png"))
        browser.close()
    print(f"{spec['id']}: {len(tl.step_ends)} previews, {tl.t / 60:.1f} min -> {out}")


def render(spec: dict, out: Path, channel, music):
    tl = build_timeline(spec)
    out.mkdir(parents=True, exist_ok=True)
    stem = out / spec["id"]
    write_srt(tl.captions, stem.with_suffix(".srt"))
    if tl.cast:
        write_cast(tl, spec, stem.with_suffix(".cast"))
    with tempfile.TemporaryDirectory() as tmp, sync_playwright() as pw:
        tmp = Path(tmp)
        browser = pw.chromium.launch(channel=channel, headless=True)
        page = browser.new_page(viewport={"width": W, "height": H})
        page.set_content(page_html(), wait_until="load")
        page.evaluate("document.fonts.ready")
        concat = []
        for i, (state, seconds) in enumerate(tl.frames):
            page.evaluate(PAGE_JS, html_state(state))
            png = tmp / f"f{i:05}.png"
            page.screenshot(path=str(png))
            concat += [f"file '{png.as_posix()}'", f"duration {seconds:.3f}"]
        concat.append(concat[-2])   # concat demuxer drops the last duration otherwise
        browser.close()
        listing = tmp / "frames.txt"
        listing.write_text("\n".join(concat), encoding="utf-8")
        total = tl.t
        cmd = ["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", str(listing)]
        if music:
            cmd += ["-stream_loop", "-1", "-i", str(music)]
        cmd += ["-vf", f"fps={FPS},fade=t=in:d=0.6,fade=t=out:st={total - 0.8:.2f}:d=0.8,format=yuv420p",
                "-c:v", "libx264", "-preset", "slow", "-crf", "20", "-tune", "stillimage"]
        if music:
            cmd += ["-af", f"volume=0.12,afade=t=in:d=1,afade=t=out:st={total - 3:.2f}:d=3",
                    "-c:a", "aac", "-b:a", "128k", "-shortest"]
        cmd += ["-movflags", "+faststart", "-t", f"{total:.2f}", str(stem.with_suffix(".mp4"))]
        subprocess.run(cmd, check=True)
    print(f"{spec['id']}: {total / 60:.1f} min, {len(tl.frames)} frames -> {stem}.mp4")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("specs", nargs="+", type=Path)
    ap.add_argument("--out", type=Path, default=HERE.parent / "out")
    ap.add_argument("--channel", default=None, help="browser channel, e.g. chrome")
    ap.add_argument("--music", type=Path, help="optional bed, mixed low under the captions")
    ap.add_argument("--deny-file", type=Path, help="extra words no spec may contain, one per line")
    ap.add_argument("--lint-only", action="store_true")
    ap.add_argument("--preview", action="store_true", help="one PNG per step instead of a video")
    args = ap.parse_args()

    deny = []
    if args.deny_file:
        deny = [w.strip() for w in args.deny_file.read_text(encoding="utf-8").splitlines() if w.strip()]
    specs, errors = [], []
    for path in args.specs:
        spec = yaml.safe_load(path.read_text(encoding="utf-8"))
        errors += lint(spec, path, deny)
        specs.append(spec)
    if errors:
        sys.exit("\n".join(errors))
    if args.lint_only:
        print(f"{len(specs)} spec(s) clean")
        return
    if args.preview:
        for spec in specs:
            render_preview(spec, args.out, args.channel)
        return
    if not shutil.which("ffmpeg"):
        sys.exit("ffmpeg not found on PATH")
    for spec in specs:
        render(spec, args.out, args.channel, args.music)


if __name__ == "__main__":
    main()
