#!/system/bin/sh
echo "== all iif lo rules =="
ip rule show 2>/dev/null | grep "iif lo" | head -25
echo "== all tun0 lookup rules =="
ip rule show 2>/dev/null | grep "tun0" | head -10
echo "== delete remaining clash tun0+lo rules =="
# repeatedly delete any rule matching "iif lo" + "tun0" or uidrange 0-99999
while ip rule show 2>/dev/null | grep -qE "iif lo.*tun0|iif lo uidrange 0-99999"; do
  RULE=$(ip rule show 2>/dev/null | grep -E "iif lo.*tun0|iif lo uidrange 0-99999" | head -1 | awk '{print $1}' | tr -d ':')
  [ -z "$RULE" ] && break
  ip rule del pref $RULE 2>/dev/null && echo "del pref $RULE ok"
done
echo "== after =="
ip rule show 2>/dev/null | grep -E "iif lo|tun0" | head -15
echo "== test =="
curl -s --max-time 4 -o /dev/null -w "lo3080=%{http_code}\n" http://127.0.0.1:3080/ 2>&1
curl -s --max-time 4 -o /dev/null -w "lo9=%{http_code}\n" http://127.0.0.1:9/ 2>&1
