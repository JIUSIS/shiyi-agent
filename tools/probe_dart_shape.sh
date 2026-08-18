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
  return new Promise((res)=>{
    const id=String(++rpcId);
    const body=JSON.stringify({type:"client-request",rpcId:id,method,payload});
    const req=http.request({host:"127.0.0.1",port:3080,path:"/api/"+method,method:"POST",headers:{"Content-Type":"application/json","Content-Length":Buffer.byteLength(body)}},r=>{
      let d="";r.on("data",c=>d+=c);r.on("end",()=>{try{res(JSON.parse(d));}catch(e){res({raw:d.slice(0,300)});}});
    });
    req.setTimeout(15000,()=>{req.destroy();res({timeout:true});});
    req.on("error",e=>res({err:e.message}));
    req.end(body);
  });
}
(async()=>{
  const c=await rpc("session.create",{title:"probe2-"+Date.now()});
  const sid=c.result&&c.result.ok?c.result.value.sessionId:null;
  console.log("create ok:",!!sid);
  // dart prompt 形态
  const p=await rpc("session.prompt",{sessionId:sid,mode:"queue",content:[{type:"text",text:"hi"}],clientTimeZone:"Asia/Shanghai"});
  console.log("prompt(dart shape):",p.result&&p.result.ok?"OK":JSON.stringify(p.result.error).slice(0,250));
  // dart subagent.list 形态
  const sub=await rpc("subagent.list",{parentSessionId:sid});
  console.log("subagent.list:",sub.result&&sub.result.ok?"OK "+JSON.stringify(sub.result.value).slice(0,80):JSON.stringify(sub.result.error).slice(0,200));
  // dart goal.create 形态
  const g=await rpc("goal.create",{sessionId:sid,objective:"probe goal"});
  console.log("goal.create:",g.result&&g.result.ok?"OK "+JSON.stringify(g.result.value).slice(0,120):JSON.stringify(g.result.error).slice(0,200));
  process.exit(0);
})().catch(e=>{console.log("FATAL",e.message);process.exit(1)});
' 2>&1