#!/system/bin/sh
echo "== mangle OUTPUT full =="
iptables -t mangle -L OUTPUT -n -v 2>/dev/null | head -40
echo "== mangle PREROUTING =="
iptables -t mangle -L PREROUTING -n 2>/dev/null | head -20
echo "== nat OUTPUT full =="
iptables -t nat -L OUTPUT -n 2>/dev/null | head -20
echo "== clash chains =="
iptables -t mangle -S 2>/dev/null | grep -iE "clash|tun|fwmark" | head -15
iptables -t nat -S 2>/dev/null | grep -iE "clash|tun|redir|redirect" | head -15
