// Offline only: no CGVirtualDisplay, NSApplication, capture, permission prompts,
// live helper launch, app restart, or persistent identity-lock acquisition.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const helper=process.argv[2] ?? path.join(root,'ThunderControl.app/Contents/MacOS/ThunderDisplaySender');
const profiles='/Library/ColorSync/Profiles/Displays';
const snapshot=()=>fs.existsSync(profiles)?fs.readdirSync(profiles).sort().map(name=>({name,mtime:fs.lstatSync(path.join(profiles,name)).mtimeMs})):[];
const before=snapshot();
const formats=[[],['--size','1920','1080','--scale','1'],['--size','1512','950','--scale','2']];
let expected;
for(let round=0;round<100;round++)for(const format of formats){
 const result=spawnSync(helper,['--identity-probe',...format],{encoding:'utf8',timeout:5000});
 assert.equal(result.status,0,result.stderr);
 expected ??=result.stdout;
 assert.equal(result.stdout,expected,'Identity changed across process or video format');
 assert.equal(result.stdout,`identity-v1 vendor=505 product=24577 serial=${process.getuid()+1}\n`);
}
for(const args of [['--origin','0','0'],['--scale','3'],['--size','0','0'],['--scale','1','--size','640','480']]){
 assert.notEqual(spawnSync(helper,['--identity-probe',...args],{timeout:5000}).status,0,'Malformed probe accepted');
}
const source=fs.readFileSync(path.join(root,'DisplaySenderHelper/DisplaySenderHelper.m'),'utf8');
assert(source.includes('d.serialNum=displaySerial;d.serialNumber=displaySerial;'));
assert(!source.includes('arc4random_uniform'),'Random identity reintroduced');
assert.deepEqual(snapshot(),before,'Offline identity tests unexpectedly altered installed profiles');
console.log('PASS 300 separate-process identity probes: fixed across reconnect simulation and 1080p/HiDPI formats');
console.log('PASS malformed options rejected; production descriptor uses same stable serial; no profile changes');
console.log('NOTE offline probes do not verify live macOS display UUID/profile reuse');
