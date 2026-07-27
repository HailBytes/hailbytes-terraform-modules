#!/usr/bin/env python3
"""Guard the fidelity of terraform test mock providers.

Why this exists
---------------
Every real defect found in the July 2026 Azure HA audit was *semantic*, not
syntactic: a missing Key Vault role assignment, a cache with no reachable
endpoint, no outbound path, an Application Gateway configured in a way
Microsoft documents as returning 502. `terraform validate` cannot see any of
that, and `terraform test` against a mock provider only sees it if the test
asserts it.

Two things make mock-provider CI meaningfully better, and this script enforces
both:

1. **Well-formed resource IDs.** The mock provider fills computed strings with
   short random tokens like "xzfymjad". Real azurerm/aws resources parse IDs
   they receive, so a short token makes the *plan* fail in a way that looks
   like a test-harness problem rather than a config problem — and worse, a
   suite that never references an ID never exercises the parser at all. Any
   `mock_resource` default `id` must look like a real ID for its cloud.

2. **Semantic assertions with a citation.** A test file that only checks
   "resource count == 1" tells you the HCL parsed. A test file that encodes a
   documented service constraint — and links the doc — tells you the topology
   is buildable. We require at least one provider-doc URL among each tier
   module's test files, so the constraints stay traceable to a source.

Run: python3 .github/scripts/mock_fidelity_check.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

# A mock id must look like a real resource ID for its cloud.
AZURE_ID = re.compile(r"^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/")
AWS_ARN = re.compile(r"^arn:aws[a-z-]*:")
# AWS also uses bare typed identifiers (ami-…, vpc-…, subnet-…, sg-…).
AWS_BARE = re.compile(r"^(ami|vpc|subnet|sg|sgr|i|vol|snap|eni|rtb|igw|nat|eipalloc|lt|tg|acl|pl)-[0-9a-f]{8,}$")

# Some mocked attributes legitimately aren't IDs.
NON_ID_KEYS = {"name", "hostname", "fqdn", "primary_access_key", "address", "ip_address"}

DOC_URL = re.compile(r"https?://(learn\.microsoft\.com|docs\.aws\.amazon\.com|registry\.terraform\.io)/\S+")


def mock_blocks(text: str):
    """Yield (resource_type, body) for each mock_resource block."""
    for m in re.finditer(r'mock_resource\s+"([^"]+)"\s*\{', text):
        rtype = m.group(1)
        depth, i = 1, m.end()
        while i < len(text) and depth:
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
            i += 1
        yield rtype, text[m.end() : i - 1]


def main() -> int:
    problems: list[str] = []
    tier_dirs: dict[Path, list[Path]] = {}

    for f in sorted(REPO.glob("modules/*/*/tests/*.tftest.hcl")):
        text = f.read_text()
        rel = f.relative_to(REPO)
        cloud = "azure" if "/azure/" in str(f) else "aws"
        tier_dirs.setdefault(f.parent, []).append(f)

        for rtype, body in mock_blocks(text):
            for key, value in re.findall(r'(\w+)\s*=\s*"([^"]*)"', body):
                if key in NON_ID_KEYS or not value:
                    continue
                if key != "id" and not key.endswith("_id") and key != "arn":
                    continue
                looks_real = (
                    AZURE_ID.match(value)
                    if cloud == "azure"
                    else (AWS_ARN.match(value) or AWS_BARE.match(value))
                )
                if not looks_real:
                    problems.append(
                        f"{rel}: mock_resource \"{rtype}\" sets {key} = \"{value}\", which is not a "
                        f"well-formed {cloud} identifier.\n"
                        f"    The provider parses IDs it is handed; a short token makes the plan fail\n"
                        f"    in a way that looks like a harness bug. Use a full "
                        + (
                            "/subscriptions/<uuid>/resourceGroups/<rg>/providers/... path."
                            if cloud == "azure"
                            else "arn:aws:... ARN or a typed id like vpc-0123456789abcdef0."
                        )
                    )

    # Each tier module's test suite should cite at least one provider/service doc,
    # so the semantic assertions are traceable rather than folklore.
    for tdir, files in sorted(tier_dirs.items()):
        if not any(DOC_URL.search(f.read_text()) for f in files):
            rel = tdir.relative_to(REPO)
            problems.append(
                f"{rel}: no provider or service documentation URL cited anywhere in this\n"
                f"    module's tests. Mock-provider tests that only count resources prove the\n"
                f"    HCL parsed, not that the topology is buildable. Encode at least one\n"
                f"    documented service constraint and link the source — see\n"
                f"    modules/ha-hot-hot/azure/tests/appgw.tftest.hcl for the pattern."
            )

    if problems:
        print("Mock fidelity check failed:\n")
        for p in problems:
            print(f"  - {p}\n")
        print(f"{len(problems)} problem(s). See the docstring in this script for why these matter.")
        return 1

    print(f"Mock fidelity OK across {len(tier_dirs)} tier module test suites.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
