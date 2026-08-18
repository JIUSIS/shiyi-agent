#!/system/bin/sh
echo "== tcpdump tun0 ALL packets while curl 127.0.0.1:39999 =="
timeout 6 tcpdump -i tun0 -c 20 2>&1 | head -22 &
sleep 1
curl -s --max-time 4 -o /dev/null -w "curl=%{http_code}\n" http://127.0.0.1:39999/ 2>&1
wait
echo "== tcpdump lo ALL during curl =="
timeout 6 tcpdump -i lo -c 10 2>&1 | head -12 &
sleep 1
curl -s --max-time 4 -o /dev/null -w "curl=%{http_code}\n" http://127.0.0.1:39999/ 2>&1
wait
