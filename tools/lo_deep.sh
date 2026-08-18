#!/system/bin/sh
echo "== sysctl tcp =="
for k in tcp_syncookies tcp_tw_reuse tcp_fin_timeout tcp_abort_on_overflow tcp_max_syn_backlog; do
  echo "$k=$(cat /proc/sys/net/ipv4/$k 2>/dev/null)"
done
echo "== lo iface =="
ip addr show lo 2>/dev/null | head -6
echo "== lo routes =="
ip route show table local 2>/dev/null | grep "dev lo" | head -6
echo "== ipv6 loopback =="
cat /proc/net/tcp6 2>/dev/null | grep -i "00000000000000000000000001000000" | head -4
echo "== try IPv6 localhost =="
(curl -g -s --max-time 3 -o /dev/null -w "v6=%{http_code}\n" "http://[::1]:39999/" 2>&1) || echo "v6 fail"
echo "== try 0.0.0.0 target =="
(curl -s --max-time 3 -o /dev/null -w "zero=%{http_code}\n" "http://0.0.0.0:39999/" 2>&1) || echo "zero fail"
echo "== conntrack count =="
cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null
cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null
