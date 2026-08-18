#!/system/bin/sh
echo "== my rule still there? =="
ip rule show 2>/dev/null | grep -E "15000|127\.0"
echo "== tcpdump on lo (3s) =="
which tcpdump 2>&1
timeout 3 tcpdump -i lo -c 5 port 3080 2>&1 | head -8 &
sleep 1
curl -s --max-time 2 -o /dev/null -w "curl=%{http_code}\n" http://127.0.0.1:3080/ 2>&1
wait
echo "== tcpdump on tun0 (3s) =="
timeout 3 tcpdump -i tun0 -c 5 port 3080 2>&1 | head -8 &
sleep 1
curl -s --max-time 2 -o /dev/null -w "curl=%{http_code}\n" http://127.0.0.1:3080/ 2>&1
wait
