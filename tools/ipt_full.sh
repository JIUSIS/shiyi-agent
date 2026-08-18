#!/system/bin/sh
echo "== ALL iptables rules (all tables) =="
iptables -S 2>/dev/null | grep -viE "^-P|^-N" | head -40
echo "== NAT full =="
iptables -t nat -S 2>/dev/null | grep -viE "^-P|^-N" | head -30
echo "== MANGLE full =="
iptables -t mangle -S 2>/dev/null | grep -viE "^-P|^-N" | head -30
echo "== search clash/tun/7890/1053 =="
for t in filter nat mangle raw; do
  iptables -t $t -S 2>/dev/null | grep -iE "clash|tun|7890|1053|redir|tproxy|mark" | head -10
done
echo "== ip6tables =="
ip6tables -t nat -S 2>/dev/null | grep -viE "^-P|^-N" | head -10
