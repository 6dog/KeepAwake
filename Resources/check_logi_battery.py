#!/usr/bin/env python3
"""Query Logitech wireless mouse battery via HID++ 2.0."""

import hid
import json
import sys
import time

VID = 0x046D
PID = 0xC539

SHORT = 0x10
LONG = 0x11
LONG_LEN = 20
SW_ID = 0xC

_VOLT_CURVE = [
    (4186, 100),
    (4156, 95),
    (4112, 90),
    (4063, 85),
    (4015, 80),
    (3970, 75),
    (3927, 70),
    (3886, 65),
    (3854, 60),
    (3825, 55),
    (3799, 50),
    (3777, 45),
    (3756, 40),
    (3737, 35),
    (3719, 30),
    (3700, 25),
    (3683, 20),
    (3666, 15),
    (3645, 10),
    (3626, 5),
    (3500, 0),
]


def _voltage_to_percent(mv):
    if mv >= _VOLT_CURVE[0][0]:
        return 100
    if mv <= _VOLT_CURVE[-1][0]:
        return 0
    for (v_hi, p_hi), (v_lo, p_lo) in zip(_VOLT_CURVE, _VOLT_CURVE[1:]):
        if v_lo <= mv <= v_hi:
            return round(p_lo + (p_hi - p_lo) * (mv - v_lo) / (v_hi - v_lo))
    return 0


def _hidpp_call(dev, dev_idx, feature_idx, function_idx, params=b"", timeout_ms=1500):
    fn_byte = (function_idx << 4) | SW_ID
    payload = (params + b"\x00" * 3)[:3]
    dev.write(bytes([SHORT, dev_idx, feature_idx, fn_byte]) + payload)
    deadline = time.time() + timeout_ms / 1000
    while time.time() < deadline:
        rsp = dev.read(LONG_LEN, timeout_ms=200)
        # Every response consumed below needs bytes 0...6. Some HID backends can
        # return truncated packets, so ignore those instead of indexing past them.
        if not rsp or len(rsp) < 7:
            continue
        rsp = bytes(rsp)
        if rsp[0] not in (SHORT, LONG) or rsp[1] != dev_idx:
            continue
        if rsp[2] == 0x8F:
            raise RuntimeError(f"HID++1 error {rsp[:7].hex()}")
        if rsp[2] == 0xFF:
            raise RuntimeError(f"HID++2 error {rsp[6]}")
        if rsp[2] == feature_idx and rsp[3] == fn_byte:
            return rsp
    raise TimeoutError(f"timeout feat={feature_idx} fn={function_idx}")


def _get_feature_index(dev, dev_idx, feat_id):
    rsp = _hidpp_call(dev, dev_idx, 0x00, 0x00, feat_id.to_bytes(2, "big"))
    return rsp[4] if rsp[4] != 0 else None


def _query(dev, dev_idx):
    idx = _get_feature_index(dev, dev_idx, 0x1004)
    if idx:
        rsp = _hidpp_call(dev, dev_idx, idx, 0x01)
        smap = {
            0: "discharging",
            1: "charging",
            2: "charging slow",
            3: "charging done",
            4: "error",
        }
        return {
            "feature": "0x1004",
            "percent": rsp[4],
            "status": smap.get(rsp[6], f"status {rsp[6]}"),
        }

    idx = _get_feature_index(dev, dev_idx, 0x1001)
    if idx:
        rsp = _hidpp_call(dev, dev_idx, idx, 0x00)
        mv = (rsp[4] << 8) | rsp[5]
        flags = rsp[6]
        if flags & 0x80:
            status = "charging fast" if flags & 0x08 else "charging"
        elif flags & 0x40:
            status = "critical"
        elif flags & 0x20:
            status = "low"
        else:
            status = "discharging"
        return {
            "feature": "0x1001",
            "percent": _voltage_to_percent(mv),
            "mv": mv,
            "status": status,
        }

    idx = _get_feature_index(dev, dev_idx, 0x1000)
    if idx:
        rsp = _hidpp_call(dev, dev_idx, idx, 0x00)
        smap = {
            0: "discharging",
            1: "recharging",
            2: "almost full",
            3: "full",
            4: "slow",
            5: "invalid",
            6: "thermal err",
        }
        return {
            "feature": "0x1000",
            "percent": rsp[4],
            "status": smap.get(rsp[6], f"status {rsp[6]}"),
        }

    return None


def read_battery():
    """Return {"ok": bool, "error": str|None, "percent": int, "mv": int, "status": str, "feature": str}."""
    path = next(
        (
            d["path"]
            for d in hid.enumerate(VID, PID)
            if d["usage_page"] == 0xFF00 and d["usage"] == 0x01
        ),
        next(
            (d["path"] for d in hid.enumerate(VID, PID) if d["usage_page"] == 0xFF00),
            None,
        ),
    )
    if not path:
        return {"ok": False, "error": "receiver not found"}
    dev = hid.device()
    try:
        dev.open_path(path)
    except OSError as e:
        return {"ok": False, "error": f"open failed: {e}"}
    try:
        for dev_idx in (0x01, 0x02, 0x03, 0xFF):
            try:
                _hidpp_call(dev, dev_idx, 0x00, 0x01, b"\x00\x00\xaa")
            except (TimeoutError, RuntimeError):
                continue
            bat = _query(dev, dev_idx)
            if not bat:
                return {"ok": False, "error": "no battery feature"}
            return {"ok": True, "error": None, **bat}
        return {"ok": False, "error": "mouse asleep or out of range"}
    finally:
        dev.close()


def main():
    if "--json" in sys.argv:
        print(json.dumps(read_battery(), separators=(",", ":")))
        return 0

    if "--quiet" in sys.argv:
        r = read_battery()
        print(f"{r['percent']}%" if r["ok"] else "?")
        return 0 if r["ok"] else 1
    r = read_battery()
    if not r["ok"]:
        print(r["error"], file=sys.stderr)
        return 1
    parts = [f"{r['percent']}%"]
    if "mv" in r:
        parts.append(f"{r['mv']} mV")
    parts.append(r["status"])
    print("battery:", "  ".join(parts))
    return 0


if __name__ == "__main__":
    sys.exit(main())
