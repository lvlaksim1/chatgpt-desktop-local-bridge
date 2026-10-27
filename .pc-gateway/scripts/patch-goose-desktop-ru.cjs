'use strict';
const fs=require('node:fs');
const path=require('node:path');
const asar=require('D:/LocalAI/Goose/patch-tools/node_modules/@electron/asar');
const root=process.argv[2];
if(!root)throw Error('Missing target portable Goose Desktop directory');
const resources=path.join(root,'resources');
const archive=path.join(resources,'app.asar');
const originalArchive=path.join(resources,'app.asar.original');
const unpacked=path.join(resources,'app.asar.unpacked');
const temp=path.join('D:/LocalAI/Goose/patch-tools','goose-ru-staging');
const patchMarker='/* GOOSE_RU_NATIVE_MENU_PATCH_V1 */';
const translations={
'File':'Файл','Edit':'Правка','View':'Вид','Window':'Окно','Help':'Справка',
'Add to dictionary':'Добавить в словарь','Cut':'Вырезать','Copy':'Копировать',
'Paste':'Вставить','New Window':'Новое окно','Settings':'Настройки',
'Find…':'Найти…','Find Next':'Найти далее','Find Previous':'Найти ранее',
'Use Selection for Find':'Найти выделенное','Find':'Найти',
'New Chat':'Новый чат','New Chat Window':'Новое окно чата',
'Open Directory...':'Открыть папку…','Open Directory…':'Открыть папку…',
'Recent Directories':'Недавние папки','Focus Goose Window':'Перейти к окну Goose',
'Quick Launcher':'Быстрый запуск','Always on Top':'Поверх всех окон',
'Toggle Navigation':'Показать или скрыть навигацию','About Goose':'О программе Goose',
'Undo':'Отменить','Redo':'Повторить','Select All':'Выделить всё',
'Delete':'Удалить','Speech':'Речь','Reload':'Перезагрузить',
'Force Reload':'Перезагрузить принудительно',
'Toggle Developer Tools':'Инструменты разработчика',
'Actual Size':'Фактический размер','Reset Zoom':'Сбросить масштаб',
'Zoom In':'Увеличить масштаб','Zoom Out':'Уменьшить масштаб',
'Toggle Full Screen':'Переключить полноэкранный режим',
'Toggle Fullscreen':'Переключить полноэкранный режим',
'Minimize':'Свернуть','Close':'Закрыть','Close Window':'Закрыть окно',
'Quit':'Выход','Exit':'Выход','Bring All to Front':'На передний план',
'Emoji & Symbols':'Эмодзи и символы','Start Dictation…':'Начать диктовку…',
'Hide Goose':'Скрыть Goose','Hide Others':'Скрыть остальные',
'Show All':'Показать всё','Services':'Службы','Print':'Печать',
'Zoom':'Масштаб','Open':'Открыть','Copy Link':'Копировать ссылку'
};
const hook=[
patchMarker,
"try {",
"  const m = require('electron').Menu;",
"  const ruLabels = "+JSON.stringify(translations)+";",
"  const translate = items => {",
"    if (!items || !Array.isArray(items)) return;",
"    for (const item of items) {",
"      const label = (item.label || '').replace(/&/g, '');",
"      if (Object.prototype.hasOwnProperty.call(ruLabels,label)) item.label = ruLabels[label];",
"      if (item.submenu && item.submenu.items) translate(item.submenu.items);",
"    }",
"  };",
"  const oldSet = m.setApplicationMenu;",
"  m.setApplicationMenu = function(menu) {",
"    if ((process.env.GOOSE_LOCALE || '').toLowerCase().startsWith('ru') && menu) translate(menu.items);",
"    return oldSet.call(this,menu);",
"  };",
"  const oldPopup = m.prototype.popup;",
"  m.prototype.popup = function(...args) {",
"    if ((process.env.GOOSE_LOCALE || '').toLowerCase().startsWith('ru')) translate(this.items);",
"    return oldPopup.apply(this,args);",
"  };",
"} catch(err) { console.error('Russian menu patch not initialized',err); }"
].join('\n');
async function main(){
 if(!fs.existsSync(archive))throw Error('Target app.asar missing: '+archive);
 if(fs.existsSync(unpacked))throw Error('Target has app.asar.unpacked; aborting to preserve native dependencies');
 const files=asar.listPackage(archive).map(f=>f.replace(/^[\\/]+/,'').replace(/\\/g,'/'));
 const mainPath=files.find(f=>f==='.vite/build/main.js');
 if(!mainPath)throw Error('Compiled Electron main script was not found');
 if(fs.existsSync(temp))fs.rmSync(temp,{recursive:true,force:true});
 fs.mkdirSync(temp,{recursive:true});
 asar.extractAll(archive,temp);
 const mainfile=path.join(temp,...mainPath.split('/'));
 let mainContent=fs.readFileSync(mainfile,'utf8');
 if(mainContent.includes(patchMarker))throw Error('Menu patch already applied');
 mainContent=hook+'\n'+mainContent;
 fs.writeFileSync(mainfile,mainContent,'utf8');
 let rendererPath='',nAttach=0,nDiagnostic=0;
 for(const f of files.filter(f=>f.endsWith('.js')&&f.includes('.vite/renderer/'))){
  const full=path.join(temp,...f.split('/'));
  if(!fs.existsSync(full))continue;
  let contents=fs.readFileSync(full,'utf8');
  if(contents.includes('Attach file')){
   nAttach=(contents.match(/Attach file/g)||[]).length;
   if(nAttach!==1)throw Error('Expected one attachment tooltip, found '+nAttach);
   rendererPath=f;
   contents=contents.replace('Attach file','Прикрепить файл');
   if(contents.includes('Generate diagnostics bundle')){
    nDiagnostic=(contents.match(/Generate diagnostics bundle/g)||[]).length;
    contents=contents.replace('Generate diagnostics bundle','Сформировать диагностический архив');
   }
   fs.writeFileSync(full,contents,'utf8');
  }
 }
 if(nAttach!==1)throw Error('Attachment tooltip not found exactly once');
 const tempArchive=archive+'.ru-new';
 if(fs.existsSync(tempArchive))fs.rmSync(tempArchive);
 await asar.createPackage(temp,tempArchive);
 const check1=asar.extractFile(tempArchive,mainPath).toString('utf8');
 const check2=asar.extractFile(tempArchive,rendererPath).toString('utf8');
 if(!check1.includes(patchMarker)||!check2.includes('Прикрепить файл'))throw Error('Repacked archive validation failed');
 if(fs.existsSync(originalArchive))throw Error('Backup already exists: no overwrite');
 fs.copyFileSync(archive,originalArchive);
 fs.renameSync(tempArchive,archive);
 fs.rmSync(temp,{recursive:true,force:true});
 console.log(JSON.stringify({status:'success',main:mainPath,renderer:rendererPath,attachments:nAttach,diagnostics:nDiagnostic,size:fs.statSync(archive).size,original_size:fs.statSync(originalArchive).size,backup:originalArchive}));
}
main().catch(err=>{console.error(err.stack||String(err));process.exitCode=1});
