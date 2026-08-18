#!/system/bin/sh
echo "== rules before =="
ip rule show 2>/dev/null | grep -E "iif lo|24000|16000" | head -10
echo "== delete clash lo-hijack rules (test) =="
# FlClash adds: iif lo lookup tun0 for all uids
ip rule del pref 24000 2>/dev/null && echo "del 24000 ok"
ip rule del pref 16000 2>/dev/null && echo "del 16000 ok"
# also remove my 15000 (keep clean state)
ip rule del pref 15000 2>/dev/null && echo "del 15000 ok"
echo "== rules after =="
ip rule show 2>/dev/null | grep -E "iif lo|24000|16000|15000" | head -10
echo "== test curl 3080 =="
curl -s --max-time 4 -o /dev/null -w "lo3080=%{http_code}\n" http://127.0.0.1:3080/ 2>&1
echo "== test curl discard =="
curl -s --max-time 4 -o /dev/null -w "lo9=%{http_code}\n" http://127.0.0.1:9/ 2>&1
