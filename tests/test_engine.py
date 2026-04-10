"""
LRB Strategy — Tests
Run: python tests/test_engine.py
"""
import sys
sys.path.insert(0, "engine")

from filters import range_filter, trend_filter, SweepDetector
from trade_manager import run_trade
from datetime import date, datetime

def test_range_filter():
    ok,_=range_filter(250); assert ok
    ok,_=range_filter(50);  assert not ok
    ok,_=range_filter(500); assert not ok
    print("✓ range_filter")

def test_trend_filter():
    dates=[date(2026,1,i) for i in range(2,28) if date(2026,1,i).weekday()<5]
    closes={d:50000-i*100 for i,d in enumerate(dates)}
    direction,_=trend_filter(dates[-1],dates,closes)
    assert direction=="DOWN", f"Expected DOWN, got {direction}"
    closes[dates[-1]]=60000
    direction,_=trend_filter(dates[-1],dates,closes)
    assert direction=="UP"
    print("✓ trend_filter")

def test_sweep_buy():
    det=SweepDetector(44000,43500,"BUY",1)
    r=det.update(0,{"h":44050,"l":43900,"c":43990})
    assert r is None and det.liq_bull
    r=det.update(1,{"h":44100,"l":44000,"c":44010})
    assert r and r[0]=="BUY"
    print("✓ SweepDetector BUY")

def test_sweep_no_entry_without_sweep():
    det=SweepDetector(44000,43500,"BUY",1)
    for i in range(10):
        r=det.update(i,{"h":43999,"l":43600,"c":43800})
        assert r is None
    print("✓ SweepDetector: no entry without sweep")

# Fixed test config — independent of config.py changes
TEST_CFG = {"sl_pips": 100, "cp1_pips": 40, "cp2_pips": 80, "cp3_pips": 120, "cp4_pips": 250, "spread": 2, "slippage": 1}

def test_trade_cp4():
    entry={"c":44000,"dt":datetime(2026,1,1,15,0)}
    # en = 44003 (BUY+adj). cp1=40 → t2_sl=44003. cp2=80 → t2_sl=44043. cp3=120 → t2_sl=44083. cp4=250 → exit.
    bars=[{"h":44060,"l":44020,"c":44050},   # cp1 hit (pips=47), low safe
          {"h":44100,"l":44050,"c":44091},   # cp2 hit (pips=88), low > 44043
          {"h":44300,"l":44100,"c":44260}]   # cp4 hit (pips=257), low > 44083
    r=run_trade(entry,"BUY",bars,TEST_CFG)
    assert r.exit_reason=="CP4 full target", f"Expected CP4, got {r.exit_reason}"
    assert abs(r.exit_pips-165.0)<2, f"Expected ~165p, got {r.exit_pips}"
    print("✓ trade_manager CP4")

def test_trade_sl():
    entry={"c":44000,"dt":datetime(2026,1,1,15,0)}
    r=run_trade(entry,"BUY",[{"h":44000,"l":43895,"c":43910}],TEST_CFG)
    assert r.outcome=="loss" and r.exit_reason=="SL hit"
    print("✓ trade_manager SL")

def test_trade_be_stop():
    entry={"c":44000,"dt":datetime(2026,1,1,15,0)}
    bars=[{"h":44060,"l":44000,"c":44050},{"h":44005,"l":43995,"c":43998}]
    r=run_trade(entry,"BUY",bars,TEST_CFG)
    assert r.cp1_hit and r.exit_reason=="BE stop"
    print("✓ trade_manager BE stop")

if __name__=="__main__":
    print("Running LRB strategy tests...\n")
    test_range_filter()
    test_trend_filter()
    test_sweep_buy()
    test_sweep_no_entry_without_sweep()
    test_trade_cp4()
    test_trade_sl()
    test_trade_be_stop()
    print("\nAll tests passed ✓")
