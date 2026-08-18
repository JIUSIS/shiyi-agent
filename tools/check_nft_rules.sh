#!/system/bin/sh
echo "== iptables -S (all tables) =="
for t in filter mangle nat raw; do
  echo "--- table $t ---"
  iptables -t $t -S 2>/dev/null
done
echo "== ip6tables INPUT =="
ip6tables -S INPUT 2>/dev/null
echo "== nft ruleset (first 100 lines) =="
nft list ruleset 2>/dev/null | head -100
echo "== conntrack entries mentioning 3080 =="
cat /proc/net/nf_conntrack 2>/dev/null | grep 3080 | head -5
echo "== eBPF programs attached =="
ls -la /sys/fs/bpf 2>/dev/null | head -20
cat /proc/net/xt_qtaguid/stats 2>/dev/null | head -3
