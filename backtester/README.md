# LRB Backtester

Browser-based backtesting UI. Parameters are auto-injected from `engine/config.py`.

## 🚀 Quick Start

```bash
# Build once (from repo root)
python backtester/build.py

# Build + auto-open in browser
python backtester/build.py --open

# Watch mode: auto-rebuild when any Python file changes
python backtester/build.py --watch
```

Then open `backtester/generated/LRB_V2.html` in your browser.

## Architecture

```
backtester/
├── build.py           ← build script — run this
├── template/
│   └── index.html     ← HTML template — edit this for UI changes
├── generated/         ← GITIGNORED — never edit, always rebuilt
│   └── LRB_V2.html    ← open this in browser
└── README.md
```

## 🔄 Workflow

1. **Change a parameter** → edit `engine/config.py`
2. **Rebuild** → `python backtester/build.py`
3. **Test** → open `generated/LRB_V2.html`, drop your CSV

The HTML always reflects the current `engine/config.py` values.
No manual sync needed — the build script handles it.

## What the build does

1. Imports `engine/config.py` directly (no subprocess, no parsing)
2. Converts all Python dicts to JS constants
3. Injects them between `<!-- BUILD:CONFIG_START -->` and `<!-- BUILD:CONFIG_END -->` markers in the template
4. Writes `generated/LRB_V2.html`

## Template markers

The template (`template/index.html`) uses these markers:

```html
<!-- BUILD:CONFIG_START -->
<!-- default values here (used if opened without building) -->
<!-- BUILD:CONFIG_END -->
```

Everything between the markers is replaced on each build.

## CI/CD (optional)

If you add GitHub Actions later, add a step:
```yaml
- run: python backtester/build.py
- uses: actions/upload-artifact@v3
  with:
    name: LRB_V2_backtester
    path: backtester/generated/LRB_V2.html
```
This auto-builds the HTML on every push and makes it downloadable from GitHub.
