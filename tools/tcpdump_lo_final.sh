#!/system/bin/sh
echo "== tcpdump lo during curl 3080 =="
timeout 6 tcpdump -i lo -c 8 "port 3080" 2>&1 | head -10 &
sleep 1
curl -s --max-time 4 -o /dev/null -w "curl=%{http_code}\n" http://127.0.0.1:3080/ 2>&1
wait
echo "== tcpdump lo during curl 9 =="
timeout 6 tcpdump -i lo -c 6 2>&1 | head -8 &
sleep 1
curl -s --max-time 3 -o /dev/null -w "curl9=%{http_code}\n" http://127.0.0.1:9/ 2>&1
wait
echo "== conntrack table =="
cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null
cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null
echo "== lo flags =="
ip link show lo 2>&1 | head -3
