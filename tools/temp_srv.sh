#!/system/bin/sh
U=/data/user/0/com.shiyi.agent/files/termux/usr
P=/data/user/0/com.shiyi.agent/files/termux
export HOME="$P/home"
export TMPDIR="$P/tmp"
export PATH="$U/bin:/system/bin"
export LD_LIBRARY_PATH="$U/lib"
export OPENSSL_CONF="$U/etc/tls/openssl.cnf"
echo "== start temp http server on 39999 =="
nohup "$U/bin/node" -e '
const http=require("http");
http.createServer((req,res)=>{res.end("TEMP_OK")}).listen(39999,"127.0.0.1",()=>console.log("TEMP LISTENING 39999"));
setInterval(()=>{},1000);' > "$P/tmp/temp_srv.log" 2>&1 &
echo "started $!"
sleep 3
echo "== curl temp 39999 =="
curl -s --max-time 4 -w " [%{http_code}]\n" http://127.0.0.1:39999/ 2>&1
echo "== nc temp 39999 =="
(echo -e "GET / HTTP/1.0\r\n\r"; sleep 2) | timeout 5 nc 127.0.0.1 39999 2>&1 | head -3
echo "nc rc=$?"
echo "== ss listener =="
ss -tln 2>/dev/null | grep -E "39999|3080"
echo "== temp log =="
cat "$P/tmp/temp_srv.log"
