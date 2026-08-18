#!/system/bin/sh
echo "== tun0 still exists? =="
ip link show tun0 2>&1 | head -3
echo "== rules referencing tun0 =="
ip rule show 2>/dev/null | grep -i "tun0" | head -8
echo "== routes referencing tun0 =="
ip route show table all 2>/dev/null | grep -i "tun0" | head -8
echo "== iptables referencing tun0 =="
iptables -t mangle -S 2>/dev/null | grep -i "tun0" | head -8
iptables -t nat -S 2>/dev/null | grep -i "tun0" | head -8
iptables -S 2>/dev/null | grep -i "tun0" | head -8
echo "== eBPF netd programs =="
ls /sys/fs/bpf/netd_shared/ 2>/dev/null | head -12
echo "== ip rule full count =="
ip rule show 2>/dev/null | wc -l
