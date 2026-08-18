#!/system/bin/sh
echo "== FlClash proc =="
ps -A | grep -i clash | head -3
echo "== iptables OUTPUT mark rules =="
iptables -t mangle -S OUTPUT 2>/dev/null | grep -iE "127\.|mark|clash|tun" | head -10
echo "== ip rule 127 =="
ip rule show 2>/dev/null | grep -E "127\.|local" | head -8
echo "== ip route get 127.0.0.1 =="
ip route get 127.0.0.1 2>&1 | head -2
echo "== ip route get 127.0.0.1 mark 0 =="
ip route get 127.0.0.1 mark 0 2>&1 | head -2
echo "== dmesg recent (net) =="
dmesg 2>/dev/null | tail -8
echo "== /proc/sys/net/ipv4/conf/lo/rp_filter =="
cat /proc/sys/net/ipv4/conf/lo/rp_filter 2>/dev/null
echo "== eBPF cgroup attach =="
cat /sys/fs/bpf/netd_shared/prog_netd_skfilter_egress_xtbpf 2>/dev/null | head -2 || echo "no egress prog file"
ls -la /sys/fs/bpf/netd_shared/ 2>/dev/null | grep -E "prog" | head -10
