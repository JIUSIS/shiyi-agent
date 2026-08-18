#!/system/bin/sh
echo "== ip route get 127.0.0.1 (root) =="
ip route get 127.0.0.1 2>&1
echo "== ip route get 127.0.0.1 from lo =="
ip route get 127.0.0.1 iif lo 2>&1
echo "== with fwmark 0 =="
ip route get 127.0.0.1 mark 0 2>&1
echo "== with fwmark 0x77 =="
ip route get 127.0.0.1 mark 0x77 2>&1
echo "== with fwmark 0x10063 =="
ip route get 127.0.0.1 mark 0x10063 2>&1
echo "== rule priority check =="
ip rule show 2>/dev/null | grep -E "15000|14999|16000|20000|24000"
