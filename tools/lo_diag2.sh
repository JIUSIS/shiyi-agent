#!/system/bin/sh
echo "== root curl loopback 3080 =="
curl -s --max-time 4 -o /dev/null -w "lo3080=%{http_code}\n" http://127.0.0.1:3080/ 2>&1
echo "== root curl loopback discard =="
curl -s --max-time 4 -o /dev/null -w "lo9=%{http_code}\n" http://127.0.0.1:9/ 2>&1
echo "== root curl loopback 7890 (clash) =="
curl -s --max-time 4 -o /dev/null -w "lo7890=%{http_code}\n" http://127.0.0.1:7890/ 2>&1
echo "== ip rule all (tail) =="
ip rule show 2>/dev/null | tail -12
echo "== iptables output mangle chain =="
iptables -t mangle -L OUTPUT -n 2>/dev/null | head -12
echo "== iptables nat =="
iptables -t nat -L OUTPUT -n 2>/dev/null | head -12
