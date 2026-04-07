"""
LRB Strategy — HTML Backtester Build Script

Usage:
  python backtester/build.py              # build once
  python backtester/build.py --watch      # rebuild on file change
  python backtester/build.py --open       # build + open in browser

How it works:
  1. Reads engine/config.py to extract all parameter values
  2. Reads engine/filters.py to extract filter logic docstrings
  3. Injects them into backtester/template.html as JS constants
  4. Writes the result to backtester/generated/LRB_V2.html

This means:
  - You NEVER manually edit the generated HTML
  - config.py is the single source of truth
  - Every deploy is always in sync with the Python engine
  - Diffs are clean — only template.html is version controlled
"""
import re
import sys
import os
import time
import subprocess
from pathlib import Path

ROOT    = Path(__file__).parent.parent
CONFIG  = ROOT / "engine" / "config.py"
FILTERS = ROOT / "engine" / "filters.py"
TRADE_M = ROOT / "engine" / "trade_manager.py"
TEMPL   = ROOT / "backtester" / "template.html"
OUT_DIR = ROOT / "backtester" / "generated"
OUT     = OUT_DIR / "LRB_V2.html"


def extract_config() -> dict:
    """Import config.py and return all parameter dicts as flat key->value."""
    sys.path.insert(0, str(ROOT / "engine"))
    import importlib
    if "config" in sys.modules:
        importlib.reload(sys.modules["config"])
    import config
    params = {}
    # Flatten all dicts from config
    for src in [config.SESSION, config.FILTERS, config.TRADE, config.RISK, config.ACCOUNT]:
        for k, v in src.items():
            params[k] = v
    # Also include timezone presets as JSON
    import json
    params["__tz_presets__"] = json.dumps(config.TIMEZONE_PRESETS)
    return params


def build_js_constants(params: dict) -> str:
    """Build a JS const block from the Python config."""
    lines = ["// AUTO-GENERATED from engine/config.py — do not edit manually"]
    lines.append("const CFG = {")
    for k, v in params.items():
        if k == "__tz_presets__":
            lines.append(f"  tz_presets: {v},")
        elif isinstance(v, bool):
            lines.append(f"  {k}: {'true' if v else 'false'},")
        elif isinstance(v, (int, float)):
            lines.append(f"  {k}: {v},")
        elif isinstance(v, str):
            lines.append(f"  {k}: '{v}',")
    lines.append("};")
    return "\n".join(lines)


def extract_version() -> str:
    """Get version from CHANGELOG.md."""
    changelog = ROOT / "CHANGELOG.md"
    if changelog.exists():
        for line in changelog.read_text().splitlines():
            m = re.search(r"##\s+\[(\d+\.\d+\.\d+)\]", line)
            if m:
                return m.group(1)
    return "2.0.1"


def build():
    """Full build: inject config into template, write generated HTML."""
    if not TEMPL.exists():
        print(f"ERROR: template not found at {TEMPL}")
        print("Create backtester/template.html first.")
        sys.exit(1)

    OUT_DIR.mkdir(exist_ok=True)

    params  = extract_config()
    js_cfg  = build_js_constants(params)
    version = extract_version()
    template = TEMPL.read_text(encoding="utf-8")

    # Inject the config JS block
    marker = "/* __CONFIG_INJECT__ */"
    if marker not in template:
        print(f"ERROR: marker '{marker}' not found in template.html")
        sys.exit(1)

    output = template.replace(marker, js_cfg)

    # Inject build metadata
    import datetime
    ts = datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M UTC")
    output = output.replace("__BUILD_VERSION__", version)
    output = output.replace("__BUILD_TIMESTAMP__", ts)

    OUT.write_text(output, encoding="utf-8")
    size = OUT.stat().st_size / 1024
    print(f"Built {OUT.name} ({size:.0f} KB) — v{version} @ {ts}")
    return OUT


def watch():
    """Rebuild whenever any engine Python file changes."""
    watch_files = list((ROOT / "engine").glob("*.py")) + [TEMPL]
    mtimes = {f: f.stat().st_mtime for f in watch_files if f.exists()}
    print(f"Watching {len(watch_files)} files. Ctrl+C to stop.")
    build()
    while True:
        time.sleep(1)
        for f in watch_files:
            if not f.exists():
                continue
            mt = f.stat().st_mtime
            if mt != mtimes.get(f, 0):
                mtimes[f] = mt
                print(f"Changed: {f.name}")
                try:
                    build()
                except Exception as e:
                    print(f"Build error: {e}")


if __name__ == "__main__":
    do_watch = "--watch" in sys.argv
    do_open  = "--open" in sys.argv

    if do_watch:
        watch()
    else:
        out = build()
        if do_open:
            import webbrowser
            webbrowser.open(f"file://{out.resolve()}")
            print("Opened in browser.")
