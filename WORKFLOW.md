# Development Workflow

Step-by-step patterns for every common task. Follow these to keep sessions fast and token-efficient.

---

## Changing a Filter Parameter

**Example: change regime threshold from 500p to 450p**

```
1. Tell Claude: "change regime_filter to 450 in config.py"
2. Claude reads engine/config.py (get_file_contents)
3. Claude edits the one line
4. Claude pushes with create_or_update_file (includes SHA)
5. You run: python engine.py --data ../data/ym.csv --tz ct
6. Compare results to baseline in CLAUDE.md
7. If better → commit message: "perf(config): regime filter 500→450p"
8. If worse → revert: "revert: regime filter back to 500p"
```

Total Claude tool calls: 2 (read + write). No wasted reads.

---

## Adding a New Filter

```
1. Open a GitHub Issue describing the filter and hypothesis
2. Tell Claude: "add [filter name] to filters.py — see issue #N"
3. Claude reads filters.py → adds function → pushes
4. Tell Claude: "add test for [filter] to tests/test_engine.py"
5. Claude reads test file → adds test → pushes
6. Tell Claude: "add [filter] to engine.py between range_filter and trend_filter"
7. Run tests + run backtest on both YM and MT5 data
8. Add [filter] to MT5 EA if results improve
9. Update CLAUDE.md key parameters table
10. Close GitHub Issue with results
```

---

## Running a Parameter Sweep

```
1. Tell Claude: "sweep regime_filter from 400 to 600 in steps of 25 on YM data"
2. Claude generates and runs the sweep in a Python script (bash_tool)
3. Claude shows results table sorted by FTMO score
4. You pick the best config
5. Claude updates config.py with chosen value
```

NO back-and-forth needed — one message, one result table.

---

## Debugging a Bad Backtest Result

```
1. Tell Claude: "March 2026 shows -$180 — trace every trade"
2. Claude reads engine.py + filters.py
3. Claude runs trace: python engine.py --data ... --trace
4. Claude shows bar-by-bar trace of each loss trade
5. Root cause identified → fix proposed → tested
```

---

## Updating the MT5 EA

```
1. After confirming a Python change improves results:
2. Tell Claude: "update MT5 EA to match new [filter] in filters.py"
3. Claude reads mt5/LRB_V2_EA.mq5 + the changed filters.py
4. Claude makes targeted MQL5 translation
5. Claude pushes updated EA
6. You compile in MT5 MetaEditor and test on demo
```

---

## FTMO Challenge Preparation Checklist

```
[ ] YM 3yr: PF > 1.3, DD < 8%, all years positive
[ ] MT5 2026: WR > 50%, PF > 1.5, DD < 3%
[ ] Regime filter verified on at least 2 hostile months
[ ] NY delay verified eliminates opening-noise losses
[ ] All 7 tests passing
[ ] MT5 EA compiled without errors
[ ] MT5 EA tested on demo account for 2 weeks
[ ] Risk set to 1%/leg for Phase 1
[ ] FTMO daily guard set to 4%
[ ] Screenshot of backtest results saved
```

---

## GitHub Issues Usage

Use issues for:
- Ideas for new filters (label: `enhancement`)
- Bugs found in backtesting (label: `bug`)
- Parameter sweep requests (label: `optimization`)
- MT5 EA tasks (label: `mt5`)
- Data questions (label: `data`)

**Start each Claude session with:** "Check open issues and work on #N"

This replaces long explanations of what needs to be done.
