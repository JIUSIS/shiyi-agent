#!/system/bin/sh
echo "== current tun0/lo rules =="
ip rule show 2>/dev/null | grep -E "tun0" | head -8
echo "== mark.via est connection to 3080 still? =="
cat /proc/net/tcp 2>/dev/null | grep -i "0C08" | grep " 01 " | head -3
echo "== is mark.via connecting right now? check socket =="
for p in $(ls /proc | grep -E '^[0-9]+$'); do
  if [ -r /proc/$p/fd ] 2>/dev/null; then
    if ls -la /proc/$p/fd 2>/dev/null | grep -q "socket:\[3" ; then
      CMD=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | head -c 60)
      echo "$p: $CMD"
    fi
  fi
done 2>/dev/null | head -6
echo "== delete any tun0 rules again + test instantly =="
while ip rule show 2>/dev/null | grep -q "tun0"; do
  PREF=$(ip rule show 2>/dev/null | grep "tun0" | head -1 | awk '{print $1}' | tr -d ':')
  [ -z "$PREF" ] && break
  ip rule del pref $PREF 2>/dev/null && echo "del $PREF"
done
echo "== rules after =="
ip rule show 2>/dev/null | grep -E "tun0" | head -5
echo "== instant curl =="
curl -s --max-time 4 -o /dev/null -w "now=%{http_code}\n" http://127.0.0.1:3080/ 2>&1
