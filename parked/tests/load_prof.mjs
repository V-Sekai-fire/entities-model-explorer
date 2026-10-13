// Load-time probe: open a page cold (fresh profile), record when each console line and each
// network response finished, with bytes on the wire. usage: node load_time.mjs <url> <out.json> [port]
import { spawn } from 'node:child_process'; import { mkdtempSync, writeFileSync } from 'node:fs'; import { tmpdir } from 'node:os';
const chrome=`${process.env.HOME}/Library/Caches/ms-playwright/chromium-1243/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
const port=process.argv[4]||9345;
const br=spawn(chrome,['--headless=new',`--remote-debugging-port=${port}`,'--no-first-run',`--user-data-dir=${mkdtempSync(tmpdir()+'/c')}`,'about:blank'],{stdio:'ignore'});
const sleep=ms=>new Promise(r=>setTimeout(r,ms)); let t;
for(let i=0;i<40;i++){await sleep(250);try{t=await (await fetch(`http://127.0.0.1:${port}/json`)).json();break}catch{}}
const ws=new WebSocket(t.find(x=>x.type==='page').webSocketDebuggerUrl); await new Promise(r=>ws.onopen=r);
let id=0;const p={};let t0=0;const ev=[];const reqs={};
const now=()=>(performance.now()-t0)/1000;
ws.onmessage=m=>{const d=JSON.parse(m.data);if(d.id&&p[d.id]){p[d.id](d);delete p[d.id];return}
 if(d.method==='Runtime.consoleAPICalled'){ev.push({t:now(),log:d.params.args.map(a=>a.value??'').join(' ').slice(0,120)})}
 else if(d.method==='Network.responseReceived'){reqs[d.params.requestId]={url:d.params.response.url.split('/').slice(-2).join('/'),enc:d.params.response.headers['content-encoding']||d.params.response.headers['Content-Encoding']||'',status:d.params.response.status,start:now()}}
 else if(d.method==='Network.loadingFinished'){const r=reqs[d.params.requestId];if(r){r.done=now();r.wire=d.params.encodedDataLength}}};
const send=(method,params={})=>new Promise(r=>{p[++id]=r;ws.send(JSON.stringify({id,method,params}))});
await send('Runtime.enable'); await send('Network.enable'); await send('Network.setCacheDisabled',{cacheDisabled:true});
await send('Emulation.setDeviceMetricsOverride',{width:1440,height:900,deviceScaleFactor:1,mobile:false});
await send('Profiler.enable'); await send('Profiler.setSamplingInterval',{interval:500}); await send('Profiler.start');
t0=performance.now(); await send('Page.navigate',{url:process.argv[2]});
for(let i=0;i<120;i++){await sleep(250); if(ev.some(e=>/BOOT loaded/.test(e.log))) break;}
await sleep(500);
const prof=(await send('Profiler.stop')).result.profile; writeFileSync(process.argv[3].replace('.json','.cpuprofile'),JSON.stringify(prof));
const out={events:ev,requests:Object.values(reqs).filter(r=>r.wire>20000).sort((a,b)=>a.done-b.done)};
writeFileSync(process.argv[3],JSON.stringify(out,null,1));
for(const r of out.requests) console.log(`net ${r.done?.toFixed(2)}s ${(r.wire/1e6).toFixed(2)}MB ${r.enc} ${r.url}`);
for(const e of ev.filter(e=>/BOOT|Godot Engine|WebGpu/.test(e.log))) console.log(`log ${e.t.toFixed(2)}s ${e.log}`);
br.kill(); process.exit(0);
