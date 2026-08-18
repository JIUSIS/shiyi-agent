#!/system/bin/sh
echo "== restore system rule 12000 (iif tun0 local_network) =="
ip rule add pref 12000 from all iif tun0 lookup local_network 2>&1
echo "rc=$?"
echo "== add iptables fwmark for loopback (all uids) =="
iptables -t mangle -A OUTPUT -d 127.0.0.0/8 -j MARK --set-xmark 0x10063/0x1ffff 2>&1
echo "rc=$?"
echo "== verify =="
iptables -t mangle -L OUTPUT -n 2>/dev/null | head -8
echo "== test =="
curl -s --max-time 4 -o /dev/null -w "lo3080=%{http_code}\n" http://127.0.0.1:3080/ 2>&1
curl -s --max-time 4 -o /dev/null -w "lo9=%{http_code}\n" http://127.0.0.1:9/ 2>&1
curl -s --max-time 4 -o /dev/null -w "lo39999=%{http_code}\n" http://127.0.0.1:39999/ 2>&1
