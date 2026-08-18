#!/system/bin/sh
echo "== add loopback bypass rule (pref 15000, before clash 24000) =="
ip rule add pref 15000 from all iif lo to 127.0.0.0/8 lookup local 2>&1
echo "rc=$?"
echo "== verify rule =="
ip rule show 2>/dev/null | grep -E "15000|127"
echo "== test loopback 3080 =="
curl -s --max-time 4 -o /dev/null -w "lo3080=%{http_code}\n" http://127.0.0.1:3080/ 2>&1
echo "== test discard =="
curl -s --max-time 4 -o /dev/null -w "lo9=%{http_code}\n" http://127.0.0.1:9/ 2>&1
