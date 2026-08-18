#!/system/bin/sh
echo "== root curl 3080 =="
curl -s --max-time 4 -o /dev/null -w "root3080=%{http_code}\n" http://127.0.0.1:3080/ 2>&1
echo "== root curl 9 (unused) =="
curl -s --max-time 4 -o /dev/null -w "root9=%{http_code}\n" http://127.0.0.1:9/ 2>&1
echo "== root nc 3080 =="
(echo -e "GET / HTTP/1.0\r\n\r"; sleep 1) | timeout 4 nc 127.0.0.1 3080 2>&1 | head -3
echo "nc rc=$?"
echo "== whoami =="
id
