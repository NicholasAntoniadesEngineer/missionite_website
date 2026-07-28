"""Usage: python3 scripts/check-refs.py <site-root> — exits non-zero on any local href/src/import/url() that does not resolve inside the tree."""

import os
import re
import sys

PATTERNS = (
    re.compile(r"""\b(?:src|href)\s*=\s*["']([^"']+)["']"""),
    re.compile(r"""\b(?:import|require)\s*\(?\s*["']([^"']+)["']"""),
    re.compile(r"""\bfrom\s+["']([^"']+)["']"""),
    re.compile(r"""url\(\s*["']?([^"')]+)["']?\s*\)"""),
)
EXTERNAL = re.compile(r"^(?:[a-zA-Z][a-zA-Z0-9+.-]*:|//|#)")
SCANNED = (".html", ".js", ".css", ".svg")


def main(root):
    root = os.path.realpath(root)
    checked, missing = 0, set()
    for dirpath, _, names in os.walk(root):
        for name in sorted(names):
            if not name.endswith(SCANNED):
                continue
            path = os.path.join(dirpath, name)
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
            for pattern in PATTERNS:
                for ref in pattern.findall(text):
                    if EXTERNAL.match(ref):
                        continue
                    target = ref.split("#")[0].split("?")[0].strip()
                    if not target:
                        continue
                    base = root if target.startswith("/") else dirpath
                    resolved = os.path.normpath(os.path.join(base, target.lstrip("/")))
                    checked += 1
                    if not os.path.isfile(resolved) or not os.path.realpath(resolved).startswith(root):
                        missing.add((os.path.relpath(path, root), ref))
    for src, ref in sorted(missing):
        print(f"MISSING  {src} -> {ref}")
    print(f"local refs checked: {checked}  missing: {len(missing)}")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
