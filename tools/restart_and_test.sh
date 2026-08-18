#!/system/bin/sh
echo "== 3080 listener =="
ss -tln 2>/dev/null | grep 3080 | head -2
echo "== node procs =="
ps -A -o PID,PPID,UID,STATE 2>/dev/null | grep -E " node |node$" | head -5
echo "== dsh log =="
tail -5 /data/user/0/com.shiyi.agent/files/termux/tmp/dsh_single.log 2>&1
echo "== restart dsh if dead =="
U=/data/user/0/com.shiyi.agent/files/termux/usr
P=/data/user/0/com.shiyi.agent/files/termux
export HOME="$P/home" TMPDIR="$P/tmp" PATH="$U/bin:/system/bin" LD_LIBRARY_PATH="$U/lib" OPENSSL_CONF="$U/etc/tls/openssl.cnf"
if ! ss -tln 2>/dev/null | grep -q ":3080"; then
  nohup "$U/bin/node" --expose-internals "$U/lib/node_modules/@deepseek-ai/dsh/lib/bin.js" web > "$P/tmp/dsh_final.log" 2>&1 &
  echo "restarted $!"
  sleep 15
fi
echo "== now listener =="
ss -tln 2>/dev/null | grep 3080 | head -2
echo "== test =="
curl -s --max-time 4 -o /dev/null -w "lo3080=%{http_code}\n" http://127.0.0.1:3080/ 2>&1
tail -3 "$P/tmp/dsh_final.log" 2>/dev/null
