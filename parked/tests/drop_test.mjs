// First-time visitor test: open the page, drop a real .glb onto the Godot frame (a CDP drag of a file),
// then read the sheet's caption and take a screenshot.  usage: node drop_test.mjs <page url> <glb path> <out.png>
import { spawn } from 'node:child_process'; import { mkdtempSync, writeFileSync } from 'node:fs'; import { tmpdir } from 'node:os';
const chrome=`${process.env.HOME}/Library/Caches/ms-playwright/chromium-1243/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
const br=spawn(chrome,['--headless=new','--remote-debugging-port=9338','--no-first-run',`--user-data-dir=${mkdtempSync(tmpdir()+'/c')}`,'about:blank'],{stdio:'ignore'});
const sleep=ms=>new Promise(r=>setTimeout(r,ms)); let t;
for(let i=0;i<40;i++){await sleep(250);try{t=await (await fetch('http://127.0.0.1:9338/json')).json();break}catch{}}
const ws=new WebSocket(t.find(x=>x.type==='page').webSocketDebuggerUrl); await new Promise(r=>ws.onopen=r);
let id=0;const p={};const logs=[];ws.onmessage=m=>{const d=JSON.parse(m.data);if(d.id&&p[d.id]){p[d.id](d);delete p[d.id]}else if(d.method==='Runtime.consoleAPICalled'){logs.push(d.params.args.map(a=>a.value??a.description??'').join(' '))}else if(d.method==='Runtime.exceptionThrown'){logs.push('EXC '+(d.params.exceptionDetails.exception?.description||d.params.exceptionDetails.text))}};
const send=(method,params={})=>new Promise(r=>{p[++id]=r;ws.send(JSON.stringify({id,method,params}))});
await send('Runtime.enable');
await send('Emulation.setDeviceMetricsOverride',{width:1440,height:900,deviceScaleFactor:1,mobile:false});
await send('Page.navigate',{url:process.argv[2]}); await sleep(35000);
const shot=async f=>{const s=await send('Page.captureScreenshot',{format:'png'});writeFileSync(f,Buffer.from(s.result.data,'base64'))};
await shot(process.argv[4].replace('.png','-before.png'));
const data={items:[],files:[process.argv[3]],dragOperationsMask:1};
const x=720,y=450;
for(const type of ['dragEnter','dragOver','drop']) await send('Input.dispatchDragEvent',{type,x,y,data});
await sleep(8000);
await shot(process.argv[4]);
writeFileSync(process.argv[4].replace('.png','.log'),logs.join('\n'));
br.kill(); process.exit(0);
