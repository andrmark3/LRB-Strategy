#!/usr/bin/env python3
"""
LRB Strategy — HTML Backtester Build System

Usage:
    cd backtester
    python build.py                    # builds once
    python build.py --watch            # rebuilds on any Python change
    python build.py --open             # build + open in browser

How it works:
    1. Reads engine/config.py → extracts all parameter values
    2. Reads engine/filters.py → extracts filter logic as JS comments
    3. Injects everything into template/index.html
    4. Writes generated/LRB_V2.html

The generated file is NEVER committed to git (see .gitignore).
Always edit template/index.html or engine/*.py, never the generated file.
"""
import sys
import os
import json
import time
import subprocess
import importlib.util
from pathlib import Path
from datetime import datetime

ROOT      = Path(__file__).parent.parent
ENGINE    = ROOT / "engine"
TEMPLATE  = Path(__file__).parent / "template" / "index.html"
OUT_DIR   = Path(__file__).parent / "generated"
OUT_FILE  = OUT_DIR / "LRB_V2.html"


def load_config() -> dict:
    """Import engine/config.py and return all parameter dicts."""
    spec = importlib.util.spec_from_file_location("config", ENGINE / "config.py")
    mod  = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return {
        "SESSION":          mod.SESSION,
        "FILTERS":          mod.FILTERS,
        "TRADE":            mod.TRADE,
        "RISK":             mod.RISK,
        "ACCOUNT":          mod.ACCOUNT,
        "TIMEZONE_PRESETS": mod.TIMEZONE_PRESETS,
    }


def config_to_js(cfg: dict) -> str:
    """Convert Python config dicts into a JS const block injected into the HTML."""
    lines = ["// AUTO-GENERATED from engine/config.py — do not edit here"]
    lines.append("// Edit engine/config.py then run: python backtester/build.py")
    lines.append("")

    def py_to_js(v):
        if isinstance(v, bool): return "true" if v else "false"
        if isinstance(v, str):  return f'"{v}"'
        return str(v)

    for name, d in cfg.items():
        if not isinstance(d, dict): continue
        lines.append(f"const CFG_{name} = {{")
        for k, v in d.items():
            lines.append(f"  {k}: {py_to_js(v)},")
        lines.append("};")
        lines.append("")

    # Flat convenience aliases the template uses directly
    s = cfg["SESSION"]; f = cfg["FILTERS"]; t = cfg["TRADE"]; r = cfg["RISK"]
    tz = cfg["TIMEZONE_PRESETS"]
    lines += [
        "// Flat aliases used by the backtester UI and engine",
        f"const DEFAULT_ACCOUNT = {cfg['ACCOUNT']['balance']};",
        f"const DEFAULT_RISK    = {r['risk_per_leg_pct']};",
        f"const DEFAULT_SL      = {t['sl_pips']};",
        f"const DEFAULT_CP1     = {t['cp1_pips']};",
        f"const DEFAULT_CP2     = {t['cp2_pips']};",
        f"const DEFAULT_CP3     = {t['cp3_pips']};",
        f"const DEFAULT_CP4     = {t['cp4_pips']};",
        f"const DEFAULT_SPREAD  = {t['spread']};",
        f"const DEFAULT_SLIP    = {t['slippage']};",
        f"const DEFAULT_MINR    = {f['min_range']};",
        f"const DEFAULT_MAXR    = {f['max_range']};",
        f"const DEFAULT_REGIME  = {f['regime_filter']};",
        f"const DEFAULT_NY_DELAY= {s['ny_delay_min']};",
        f"const DEFAULT_TRLB    = {f['trend_lb']};",
        f"const DEFAULT_CONFIRM = {f['confirm_bars']};",
        f"const DEFAULT_FTMO_DG = {r['ftmo_daily_guard']};",
        f"const TZ_PRESETS      = {json.dumps(tz)};",
        "",
        "// Build metadata",
        f"const BUILD_TIME = \"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\";",
        f"const BUILD_FROM = \"engine/config.py\";",
    ]
    return "\n".join(lines)


def build() -> bool:
    """Run one build. Returns True if successful."""
    try:
        if not TEMPLATE.exists():
            print(f"ERROR: template not found at {TEMPLATE}")
            print("  Run from repo root or ensure backtester/template/index.html exists.")
            return False

        cfg     = load_config()
        js_cfg  = config_to_js(cfg)
        html    = TEMPLATE.read_text(encoding="utf-8")

        # Inject the config block between markers in the template
        marker_start = "<!-- BUILD:CONFIG_START -->"
        marker_end   = "<!-- BUILD:CONFIG_END -->"

        if marker_start not in html:
            print(f"ERROR: marker '{marker_start}' not found in template.")
            print("  Add <!-- BUILD:CONFIG_START --> and <!-- BUILD:CONFIG_END --> to template.")
            return False

        before  = html.split(marker_start)[0]
        after   = html.split(marker_end)[1]
        output  = before + marker_start + "\n<script>\n" + js_cfg + "\n</script>\n" + marker_end + after

        OUT_DIR.mkdir(exist_ok=True)
        OUT_FILE.write_text(output, encoding="utf-8")

        size = OUT_FILE.stat().st_size / 1024
        print(f"[{datetime.now().strftime('%H:%M:%S')}] Built {OUT_FILE.name} ({size:.0f} KB)")
        print(f"  Config: {len(cfg)} dicts, {sum(len(d) for d in cfg.values() if isinstance(d,dict))} params")
        print(f"  Open:   {OUT_FILE.resolve()}")
        return True

    except Exception as e:
        print(f"BUILD ERROR: {e}")
        import traceback; traceback.print_exc()
        return False


def watch():
    """Watch engine/*.py and template/*.html for changes, rebuild on change."""
    watch_paths = list(ENGINE.glob("*.py")) + list((Path(__file__).parent / "template").glob("*.html"))
    mtimes = {p: p.stat().st_mtime for p in watch_paths if p.exists()}

    print(f"Watching {len(watch_paths)} files for changes... (Ctrl+C to stop)")
    build()

    while True:
        time.sleep(0.5)
        for p in watch_paths:
            if not p.exists(): continue
            mt = p.stat().st_mtime
            if mt != mtimes.get(p):
                mtimes[p] = mt
                print(f"  Changed: {p.name}")
                build()
                break


if __name__ == "__main__":
    do_watch = "--watch" in sys.argv or "-w" in sys.argv
    do_open  = "--open" in sys.argv or "-o" in sys.argv

    if do_watch:
        watch()
    else:
        ok = build()
        if ok and do_open:
            import webbrowser
            webbrowser.open(OUT_FILE.resolve().as_uri())
        sys.exit(0 if ok else 1)
