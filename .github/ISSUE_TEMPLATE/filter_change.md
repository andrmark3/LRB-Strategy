---
name: Filter Change / Optimization
about: Propose a filter parameter change or new filter
labels: optimization
---

## What to change
<!-- e.g. "Increase regime_filter from 500p to 450p" -->

## Hypothesis
<!-- Why do you think this will improve results? -->

## Acceptance criteria
- [ ] YM 3yr PF >= current ({{ current_pf }})
- [ ] YM 3yr Max DD <= current ({{ current_dd }}%)
- [ ] MT5 2026 WR >= 50%
- [ ] All years profitable
- [ ] All 7 tests passing

## Files to change
- [ ] `engine/config.py`
- [ ] `engine/filters.py`
- [ ] `engine/engine.py`
- [ ] `tests/test_engine.py`
- [ ] `backtester/LRB_V2.html`
- [ ] `mt5/LRB_V2_EA.mq5`
- [ ] `CLAUDE.md` (update key parameters table)
