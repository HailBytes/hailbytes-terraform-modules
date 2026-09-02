#!/usr/bin/env python3
"""Warn when a wrapper module's variable metadata drifts from its core module.

The wrapper modules (asm-*, sat-*) are thin pass-throughs around the shared tier
modules. They must re-declare every core variable (enforced as a hard error by
the `wrapper-forwarding` job), but the *metadata* of those re-declarations —
`description`, `type`, `default` — can silently diverge. A drifted description
ships truncated/incorrect docs to customers via terraform-docs; a drifted
default silently overrides the core; a drifted type can accept values the core
rejects.

This check is intentionally NON-BLOCKING: it emits GitHub `::warning::`
annotations and always exits 0, so it surfaces drift in the PR without breaking
the build. Tighten to errors once the tree is clean if desired.

No third-party dependencies — a small brace-aware parser handles `variable`
blocks that contain nested `validation { ... }` blocks.
"""

import re
import sys

WRAPPERS = {
    "asm-aws-single": "single-vm/aws",
    "sat-aws-single": "single-vm/aws",
    "asm-aws-ha": "ha-hot-hot/aws",
    "sat-aws-ha": "ha-hot-hot/aws",
    "asm-aws-autoscale": "unlimited-scale/aws",
    "sat-aws-autoscale": "unlimited-scale/aws",
    "asm-azure-single": "single-vm/azure",
    "sat-azure-single": "single-vm/azure",
    "asm-azure-ha": "ha-hot-hot/azure",
    "sat-azure-ha": "ha-hot-hot/azure",
    "asm-azure-autoscale": "unlimited-scale/azure",
    "sat-azure-autoscale": "unlimited-scale/azure",
}

# Variables a wrapper deliberately does not forward.
HIDDEN = {"product"}

VAR_RE = re.compile(r'variable\s+"([^"]+)"\s*\{')


def _block_end(text, open_brace_idx):
    """Return index just past the matching close brace for the block."""
    depth = 0
    for i in range(open_brace_idx, len(text)):
        c = text[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i + 1
    return len(text)


def _attr(body, name):
    """Extract a top-level `name = <value>` from a variable block body.

    Brace/bracket-aware so multi-line type/default values and nested validation
    blocks don't confuse it. Returns the raw value text (whitespace-normalised)
    or None.
    """
    m = re.search(r'(?m)^\s*' + re.escape(name) + r'\s*=\s*', body)
    if not m:
        return None
    start = m.end()
    depth = 0
    in_str = False
    esc = False
    out = []
    for i in range(start, len(body)):
        c = body[i]
        out.append(c)
        if in_str:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
            continue
        if c == '"':
            in_str = True
        elif c in "{[(":
            depth += 1
        elif c in "}])":
            depth -= 1
        elif c == "\n" and depth == 0:
            out.pop()
            break
    return " ".join("".join(out).split())


def parse_vars(path):
    try:
        text = open(path, encoding="utf-8").read()
    except FileNotFoundError:
        return {}
    out = {}
    for m in VAR_RE.finditer(text):
        name = m.group(1)
        brace = text.index("{", m.start())
        body = text[brace + 1 : _block_end(text, brace) - 1]
        out[name] = {
            "description": _attr(body, "description"),
            "type": _attr(body, "type"),
            "default": _attr(body, "default"),
        }
    return out


# `default` and `type` change BEHAVIOUR: a wrapper forwards its own value, so a
# drifted default silently overrides the core's, and a drifted type accepts
# values the core rejects. Those fail the build. `description` is documentation
# -- worth reporting, not worth blocking a release over -- so it stays a warning.
#
# This distinction is not theoretical. b111065 flipped
# create_backup_storage_account to false on all three Azure core modules to stop
# a 403 KeyBasedAuthenticationNotPermitted, and left `true` on all six Azure
# wrappers. Because wrappers forward their own value, the fix was inert for
# every caller of the product modules -- which are the public API. This check
# printed six warnings saying exactly that, and the build stayed green.
BLOCKING_FIELDS = ("type", "default")
ADVISORY_FIELDS = ("description",)


def main():
    errors = 0
    warnings = 0
    for wrapper, core in WRAPPERS.items():
        wv = parse_vars(f"modules/{wrapper}/variables.tf")
        cv = parse_vars(f"modules/{core}/variables.tf")
        for name, c in sorted(cv.items()):
            if name in HIDDEN or name not in wv:
                continue  # missing vars are caught by the forwarding name check
            w = wv[name]
            for field in BLOCKING_FIELDS + ADVISORY_FIELDS:
                if c[field] is None or w[field] == c[field]:
                    continue
                level = "error" if field in BLOCKING_FIELDS else "warning"
                if field in BLOCKING_FIELDS:
                    errors += 1
                else:
                    warnings += 1
                print(
                    f"::{level} file=modules/{wrapper}/variables.tf::"
                    f"variable '{name}' {field} differs from core "
                    f"modules/{core}: core={c[field]!r} wrapper={w[field]!r}"
                )
    print(
        f"wrapper metadata drift check: {errors} error(s) "
        f"on {'/'.join(BLOCKING_FIELDS)}, {warnings} warning(s) on "
        f"{'/'.join(ADVISORY_FIELDS)}."
    )
    if errors:
        print(
            "::error::A wrapper's type or default differs from its core module. "
            "Wrappers forward their own value, so this silently overrides the "
            "core for every caller of the public API. Bring the two into step."
        )
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
