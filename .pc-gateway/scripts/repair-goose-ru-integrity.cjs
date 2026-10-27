'use strict';
// Keep the original Goose distribution untouched.
// Electron on Windows verifies a SHA-256 digest of the ASAR *header* stored
// in the INTEGRITY/ELECTRONASAR PE resource. Repackaged ASAR requires a
// matching digest in the corresponding executable.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {createRequire} = require('node:module');
const root = 'D:/LocalAI/Goose';
const target = path.join(root,'desktop-ru/v1.56.0');
const original = path.join(root,'desktop/v1.56.0');
const asar = require(path.join(root,'patch-tools/node_modules/@electron/asar'));
const localRequire = createRequire(path.join(root,'patch-tools/resedit-tool/loader.cjs'));
let resedit;
try { resedit = localRequire('resedit/cjs'); }
catch (_) { resedit = localRequire('resedit'); }
const exePath = path.join(target,'Goose.exe');
const archivePath = path.join(target,'resources/app.asar');
const originalExePath = path.join(original,'Goose.exe');
const originalArchive = path.join(original,'resources/app.asar');
const archiveBackup = path.join(target,'resources/app.asar.original');
const backup = exePath+'.before-ru-integrity';
const integrityValue = crypto.createHash('sha256').update(asar.getRawHeader(archivePath).headerString).digest('hex');
function invariant(ok,msg){if(!ok)throw Error(msg);}
function parseExecutable(buf){
 const exe=resedit.NtExecutable.from(buf);
 const resource=resedit.NtExecutableResource.from(exe);
 const entries=resource.entries.filter(e=>String(e.type).toUpperCase()==='INTEGRITY' && String(e.id).toUpperCase()==='ELECTRONASAR');
 invariant(entries.length===1,'Expected exactly one INTEGRITY/ELECTRONASAR resource; found '+entries.length);
 const records=JSON.parse(Buffer.from(entries[0].bin).toString('utf8'));
 invariant(Array.isArray(records),'Invalid Electron integrity resource');
 const app=records.filter(x=>String(x.file).toLowerCase().replace(/\//g,'\\')==='resources\\app.asar');
 invariant(app.length===1,'Expected exactly one resources\\app.asar integrity entry');
 return {exe,resource,entry:entries[0],records,app:app[0]};
}
invariant(fs.existsSync(originalExePath) && fs.existsSync(originalArchive),'Original Goose installation missing');
invariant(fs.existsSync(exePath) && fs.existsSync(archivePath) && fs.existsSync(archiveBackup),'Russian Goose copy or ASAR backup missing');
invariant(crypto.createHash('sha256').update(fs.readFileSync(originalArchive)).digest('hex') === crypto.createHash('sha256').update(fs.readFileSync(archiveBackup)).digest('hex'), 'Original ASAR copy does not match backup; stopping');
const nativeMenu=asar.extractFile(archivePath,'.vite/build/main.js').toString('utf8');
invariant(nativeMenu.includes('GOOSE_RU_NATIVE_MENU_PATCH_V1'),'Russian ASAR menu patch is missing');
const before=parseExecutable(fs.readFileSync(exePath));
invariant(String(before.app.alg).toLowerCase()==='sha256','Unsupported integrity algorithm '+before.app.alg);
if(before.app.value.toLowerCase()===integrityValue){
 console.log(JSON.stringify({status:'success',already_correct:true,original_exe_unchanged:true,asar_header_sha256:integrityValue}));
 process.exit(0);
}
invariant(fs.existsSync(backup)===false,'Existing backup but resource still mismatches; refusing to modify again');
fs.copyFileSync(exePath,backup);
before.app.value=integrityValue;
const payload=Buffer.from(JSON.stringify(before.records),'utf8');
before.entry.bin=payload.buffer.slice(payload.byteOffset,payload.byteOffset+payload.byteLength);
before.resource.outputResource(before.exe);
const tmp=exePath+'.ru-integrity-pending';
invariant(!fs.existsSync(tmp),'Stale pending EXE exists; stopping');
fs.writeFileSync(tmp,Buffer.from(before.exe.generate()));
const after=parseExecutable(fs.readFileSync(tmp));
invariant(after.app.value===integrityValue,'Rewritten executable integrity resource does not match ASAR header');
const swap=exePath+'.ru-integrity-swap';
invariant(!fs.existsSync(swap),'Stale swap EXE exists; stopping');
fs.renameSync(exePath,swap);
try {fs.renameSync(tmp,exePath);}
catch(err){fs.renameSync(swap,exePath);throw err;}
fs.unlinkSync(swap);
console.log(JSON.stringify({status:'success',already_correct:false,original_exe_unchanged:true,asar_header_sha256:integrityValue,exe_backup:backup}));
