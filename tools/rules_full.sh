#!/system/bin/sh
echo "== full ip rule =="
ip rule show 2>/dev/null
echo "== 7890 listening? =="
ss -tln 2>/dev/null | grep 7890 | head -2
echo "== tun0 routes =="
ip route show table tun0 2>/dev/null | head -5
echo "== all tables =="
ip route show table all 2>/dev/null | grep -E "tun0|table" | head -12
