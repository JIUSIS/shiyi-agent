#!/system/bin/sh
echo "== nft list tables =="
nft list tables 2>&1 | head -10
echo "== nft ruleset grep clash/tun =="
nft list ruleset 2>/dev/null | grep -iE "clash|tun0|127\.0\.0\.0|dport 53|mark" | head -25
echo "== iptables-nft? =="
which iptables-nft nft 2>&1
