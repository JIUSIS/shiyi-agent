#!/system/bin/sh
U=/data/user/0/com.shiyi.agent/files/termux/usr
P=/data/user/0/com.shiyi.agent/files/termux
export HOME="$P/home"
export TMPDIR="$P/tmp"
export PATH="$U/bin:/system/bin"
export LD_LIBRARY_PATH="$U/lib"
export OPENSSL_CONF="$U/etc/tls/openssl.cnf"
node -e '
const http=require("http");
let rpcId=0;
function rpc(method,payload){
  return new Promise((res,rej)=>{
    const id=String(++rpcId);
    const body=JSON.stringify({type:"client-request",rpcId:id,method,payload});
    const req=http.request({host:"127.0.0.1",port:3080,path:"/api/"+method,method:"POST",headers:{"Content-Type":"application/json","Content-Length":Buffer.byteLength(body)}},r=>{
      let d="";r.on("data",c=>d+=c);r.on("end",()=>{
        try{const j=JSON.parse(d);res(j);}catch(e){res({raw:d.slice(0,300)});}
      });
    });
    req.setTimeout(15000,()=>{req.destroy();res({timeout:true});});
    req.on("error",e=>res({err:e.message}));
    req.end(body);
  });
}
(async()=>{
  const c=await rpc("session.create",{title:"probe-"+Date.now()});
  const sid=c.result&&c.result.ok?c.result.value.sessionId:null;
  console.log("create:",JSON.stringify(c).slice(0,200));
  const p=await rpc("session.prompt",{sessionId:sid,message:"你好"});
  console.log("prompt:",JSON.stringify(p).slice(0,400));
  const sub=await rpc("subagent.list",{});
  console.log("subagents:",JSON.stringify(sub).slice(0,400));
  const g=await rpc("goal.create",{objective:"test goal probe"});
  console.log("goalCreate:",JSON.stringify(g).slice(0,300));
  process.exit(0);
})().catch(e=>{console.log("FATAL",e.message);process.exit(1)});
' 2>&1