#!/system/bin/sh
U=/data/user/0/com.shiyi.agent/files/termux/usr
P=/data/user/0/com.shiyi.agent/files/termux
export HOME="$P/home"
export TMPDIR="$P/tmp"
export PATH="$U/bin:/system/bin"
export LD_LIBRARY_PATH="$U/lib"
export OPENSSL_CONF="$U/etc/tls/openssl.cnf"
# restart temp server
pkill -f "39999" 2>/dev/null
nohup "$U/bin/node" -e 'const http=require("http");http.createServer((q,s)=>s.end("TEMP_OK")).listen(39999,"127.0.0.1",()=>console.log("LISTEN"));setInterval(()=>{},1000);' > "$P/tmp/temp_srv.log" 2>&1 &
sleep 2
echo "== tcpdump lo: nc first =="
timeout 6 tcpdump -i lo -c 10 "port 39999" 2>&1 | head -12 &
sleep 1
(echo -e "GET / HTTP/1.0\r\n\r"; sleep 2) | timeout 4 nc 127.0.0.1 39999 2>&1 | head -2
wait
echo "== tcpdump lo: node second =="
timeout 6 tcpdump -i lo -c 10 "port 39999" 2>&1 | head -12 &
sleep 1
node -e 'const http=require("http");const req=http.get("http://127.0.0.1:39999/",r=>{console.log("node:",r.statusCode);r.resume();process.exit(0)});req.setTimeout(3000,()=>{console.log("node TIMEOUT");process.exit(1)});req.on("error",e=>{console.log("node ERR:",e.message);process.exit(1)})' 2>&1
wait
