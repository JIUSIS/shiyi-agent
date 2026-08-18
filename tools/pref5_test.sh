#!/system/bin/sh
echo "== add pref 5 unconditional 127.0.0.0/8 -> local =="
ip rule add pref 5 from all to 127.0.0.0/8 lookup local 2>&1
echo "rc=$?"
ip rule show 2>/dev/null | head -6
echo "== test =="
curl -s --max-time 4 -o /dev/null -w "lo3080=%{http_code}\n" http://127.0.0.1:3080/ 2>&1
curl -s --max-time 4 -o /dev/null -w "lo9=%{http_code}\n" http://127.0.0.1:9/ 2>&1
