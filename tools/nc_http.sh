#!/system/bin/sh
U=/data/user/0/com.shiyi.agent/files/termux/usr
echo "== current ip rules (lo/tun0) =="
ip rule show 2>/dev/null | grep -E "iif lo|tun0" | head -12
echo "== nc connect with response wait (root) =="
# nc: send HTTP, wait for response
(printf 'GET / HTTP/1.0\r\n\r\n'; sleep 2) | timeout 6 nc 127.0.0.1 3080 2>&1 | head -4
echo "nc rc=$?"
echo "== tcpdump lo during curl =="
timeout 6 tcpdump -i lo -c 6 "port 3080" 2>&1 | head -8 &
sleep 1
curl -s --max-time 4 -o /dev/null -w "curl=%{http_code}\n" http://127.0.0.1:3080/ 2>&1
wait
