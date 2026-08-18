#!/system/bin/sh
echo "== full mangle OUTPUT =="
iptables -t mangle -L OUTPUT -n -v 2>/dev/null
echo "== full mangle chain list =="
iptables -t mangle -L -n 2>/dev/null | grep "^Chain" | head -20
echo "== filter OUTPUT =="
iptables -t filter -L OUTPUT -n 2>/dev/null | head -20
echo "== bpf progs =="
ls /sys/fs/bpf 2>/dev/null | head -10
tc filter show dev lo ingress 2>&1 | head -10
tc filter show dev wlan0 ingress 2>&1 | head -10
