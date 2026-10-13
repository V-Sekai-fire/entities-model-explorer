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
// Tools test: focus the canvas, then press G (grid), E (explode), W (wireframe), shooting after each.
const click=async(x,y)=>{for(const type of ['mousePressed','mouseReleased']) await send('Input.dispatchMouseEvent',{type,x,y,button:'left',clickCount:1})};
if(process.argv[3]!=='x'){const data={items:[],files:[process.argv[3]],dragOperationsMask:1};for(const type of ['dragEnter','dragOver','drop']) await send('Input.dispatchDragEvent',{type,x:720,y:450,data}); await sleep(8000); await shot(process.argv[4].replace('.png','-dropped.png'));}
await click(1000,150); await sleep(500);
const key=async(k)=>{const code='Key'+k; await send('Input.dispatchKeyEvent',{type:'keyDown',key:k.toLowerCase(),code,windowsVirtualKeyCode:k.charCodeAt(0),text:k.toLowerCase()}); await sleep(80); await send('Input.dispatchKeyEvent',{type:'keyUp',key:k.toLowerCase(),code,windowsVirtualKeyCode:k.charCodeAt(0)}); await sleep(1500)};
for(const k of ['G','E','W']){ await key(k); logs.push('KEY '+k); await shot(process.argv[4].replace('.png','-'+k+'.png')); }
writeFileSync(process.argv[4].replace('.png','.log'),logs.join('\n'));
br.kill(); process.exit(0);
