#!/system/bin/sh
echo "== kill frozen FlClash (user closed proxy) =="
kill -9 8809 13501 2>/dev/null
sleep 3
echo "== procs =="
ps -A | grep -i clash | head -3
echo "== test loopback =="
curl -s --max-time 4 -o /dev/null -w "lo3080=%{http_code}\n" http://127.0.0.1:3080/ 2>&1
curl -s --max-time 4 -o /dev/null -w "lo9=%{http_code}\n" http://127.0.0.1:9/ 2>&1
echo "== dsh alive? =="
ss -tln 2>/dev/null | grep 3080 | head -2
