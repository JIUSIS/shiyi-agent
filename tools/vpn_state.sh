#!/system/bin/sh
echo "== VPN network info =="
dumpsys connectivity 2>/dev/null | grep -E "VPN CONNECTED|created=|HttpProxy" | head -6
echo "== uid 10389 who =="
for p in $(ls /proc | grep -E '^[0-9]+$'); do
  if [ -r /proc/$p/status ] && grep -q "Uid:.*10389" /proc/$p/status 2>/dev/null; then
    echo "pid $p: $(grep -E '^(Name|Uid):' /proc/$p/status | tr '\n' ' ')"
    tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | head -c 80; echo
  fi
done
echo "== eBPF netd progs =="
ls /sys/fs/bpf/netd_shared/ 2>/dev/null | head -10
echo "== trafficcontroller bpf maps =="
ls /sys/fs/bpf/ 2>/dev/null | grep -iE "netd|traffic" | head -8
