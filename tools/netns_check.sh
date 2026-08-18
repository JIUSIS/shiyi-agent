#!/system/bin/sh
echo "== dsh proc netns vs default =="
ls -la /proc/31585/ns/net 2>/dev/null
ls -la /proc/self/ns/net 2>/dev/null
echo "== dsh proc own net tcp (3080) =="
cat /proc/31585/net/tcp 2>/dev/null | grep -i "0C08" | head -3
echo "== default net tcp (3080) =="
cat /proc/net/tcp 2>/dev/null | grep -i "0C08" | grep -i " 0A " | head -3
echo "== compare inodes =="
cat /proc/31585/net/tcp 2>/dev/null | grep -i "0C08" | grep -i " 0A " | awk '{print "proc:"$10}'
cat /proc/net/tcp 2>/dev/null | grep -i "0C08" | grep -i " 0A " | awk '{print "default:"$10}'
echo "== conntrack for 3080 =="
cat /proc/net/nf_conntrack 2>/dev/null | grep -i "3080" | head -5
echo "== tcp listen hash =="
grep -i "0C08" /proc/net/tcp 2>/dev/null | head -3
