#!/system/bin/sh
echo "== remove MY rules (pref 5, pref 15000) =="
ip rule del pref 5 2>/dev/null && echo "removed pref 5"
ip rule del pref 15000 2>/dev/null && echo "removed pref 15000"
echo "== remove MY iptables fwmark rule =="
iptables -t mangle -D OUTPUT -d 127.0.0.0/8 -j MARK --set-xmark 0x10063/0x1ffff 2>/dev/null && echo "removed fwmark"
echo "== verify ip rule head =="
ip rule show 2>/dev/null | head -8
echo "== test loopback 3080 =="
curl -s --max-time 4 -o /dev/null -w "lo3080=%{http_code}\n" http://127.0.0.1:3080/ 2>&1
curl -s --max-time 4 -o /dev/null -w "lo9=%{http_code}\n" http://127.0.0.1:9/ 2>&1
echo "== test external =="
curl -s --max-time 6 -o /dev/null -w "ext=%{http_code}\n" https://registry.npmmirror.com/ 2>&1
