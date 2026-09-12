import {BASE,SIZE,requireThat,equal,sha256,verifyRelease,writeVerified} from './core.mjs';
import {connectUSB} from './transport.mjs';
const $=id=>document.getElementById(id);
let connection=null,busy=false,backup=null,saved=false,firmware=null,restoreData=null,verified=false,backupURL=null;
const log=message=>{$('log').textContent+=`${new Date().toLocaleTimeString()} ${message}\n`;};
const status=message=>{$('status').textContent=message;log(message);};
function progress(done,total){if(total){$('progress').value=done/total*100;$('progressText').textContent=`${done.toLocaleString()} / ${total.toLocaleString()} bytes`;}}
function update(){
 $('connect').disabled=busy || !!connection || !$('model').checked || !navigator.usb;
 $('backup').disabled=busy || !connection;
 $('confirmBackup').disabled=busy || !backup;
 $('restoreFile').disabled=busy || !connection;
 $('flash').disabled=busy || !connection || !saved || !firmware || !$('consent').checked;
 $('restore').disabled=busy || !connection || !saved || !restoreData || !$('restoreConsent').checked;
 $('restart').disabled=busy || !connection || !verified;
 for(const id of ['model','consent','restoreConsent']) $(id).disabled=busy || (id==='model' && !!connection);
}
function clearBackup(){backup=null;saved=false;if(backupURL)URL.revokeObjectURL(backupURL);backupURL=null;$('save').hidden=true;$('confirmBackup').value='';$('backupStatus').textContent='バックアップを読み出してください。';}
function reset(){connection=null;verified=false;restoreData=null;clearBackup();$('restoreFile').value='';$('restoreConsent').checked=false;$('device').textContent='未接続';update();}
async function operation(action){if(busy)return;busy=true;update();try{await action();}catch(error){status(`停止: ${error.message||error}`);log('書き込み完了とは扱いません。詳細ガイドを確認してください。');}finally{busy=false;update();}}
$('connect').onclick=()=>operation(async()=>{
 connection=await connectUSB(navigator.usb,log,progress);
 $('device').textContent='AT32 DFU · 2e3c:df11 · 内部フラッシュ 256 KiB';
 status('接続しました。バックアップを保存してください');
});
$('backup').onclick=()=>operation(async()=>{
 clearBackup();verified=false;status('元のフラッシュを読み出しています');
 const c=connection;
 const bytes=await(await c.device.do_upload(c.transferSize,SIZE)).arrayBuffer();
 requireThat(connection===c && bytes.byteLength===SIZE,'バックアップが最後まで読み出せませんでした。');
 backup=bytes;
 const hash=await sha256(bytes);
 backupURL=URL.createObjectURL(new Blob([bytes],{type:'application/octet-stream'}));
 $('save').href=backupURL;$('save').download=`c100-backup-${new Date().toISOString().replace(/[:.]/g,'-')}-${hash.slice(0,12)}.bin`;$('save').hidden=false;
 $('backupStatus').textContent=`SHA-256: ${hash}`;
 status('保存リンクからダウンロードし、そのファイルを選び直してください');
});
$('confirmBackup').onchange=()=>operation(async()=>{
 saved=false;const file=$('confirmBackup').files[0];
 requireThat(file?.size===SIZE && backup,'256 KiB の保存済みバックアップを選んでください。');
 requireThat(equal(backup,await file.arrayBuffer()),'この接続で読み出したバックアップと一致しません。');
 saved=true;status('バックアップの保存内容を確認しました');
});
$('restoreFile').onchange=()=>operation(async()=>{
 restoreData=null;$('restoreConsent').checked=false;const file=$('restoreFile').files[0];
 requireThat(file?.size===SIZE,'復元には 256 KiB の生バックアップが必要です。');
 restoreData=await file.arrayBuffer();log(`復元候補 SHA-256: ${await sha256(restoreData)}`);
});
async function write(data,restoring){
 requireThat(connection && saved && backup,'現在の接続のバックアップ保存が必要です。');
 verified=false;status(restoring?'バックアップを復元しています':'専用ファームウェアを書き込んでいます');
 const c=connection;
 await writeVerified(c.device,data,c.transferSize,(done,total)=>{progress(done,total);if(done===total)status('書き込み完了。読み戻して照合しています');});
 requireThat(connection===c,'照合中に接続が失われました。');
 verified=true;status('読み戻し一致。再起動できます');
 $('next').textContent=restoring?'再起動後、通常のキー入力を確認してください。Companion デーモンは停止したままにします。':'再起動後、Companion デーモンを起動し、接続と LED・アクションを確認してください。';
}
$('flash').onclick=()=>operation(async()=>{requireThat($('consent').checked && firmware,'専用化の確認と配布イメージが必要です。');await write(firmware,false);});
$('restore').onclick=()=>operation(async()=>{requireThat($('restoreConsent').checked && restoreData,'復元ファイルと本体の確認が必要です。');await write(restoreData,true);});
$('restart').onclick=()=>operation(async()=>{
 requireThat(verified && connection,'読み戻し照合が必要です。');
 const c=connection;verified=false;
 await c.device.abortToIdle();await c.device.dfuseCommand(0x21,BASE,4);
 status('再起動を要求します。通常 USB 接続は別途確認してください');
 try{await c.device.download(new ArrayBuffer(),0);await c.device.getStatus();}catch(error){log(`DFU 終了時: ${error.message||error}（再起動成功は未確認）`);}
 await c.device.close();reset();status('DFU 接続を終了しました。通常の USB 接続を確認してください');
});
for(const id of ['model','consent','restoreConsent'])$(id).onchange=update;
navigator.usb?.addEventListener('disconnect',event=>{if(connection?.device.device_===event.device){reset();status('USB が切断されました。再接続時はバックアップ確認から始めます');}});
window.addEventListener('beforeunload',event=>{if(busy){event.preventDefault();event.returnValue='';}});
if(!navigator.usb || !window.isSecureContext) status('HTTPS または localhost で Chrome を使って開いてください');
update();
(async()=>{try{
 const response=await fetch('firmware/manifest.json',{cache:'no-store'});requireThat(response.ok,'配布イメージはまだ用意されていません。');const manifest=await response.json();
 requireThat(manifest.file==='companion.bin','配布ファイル名が不正です。');
 const imageResponse=await fetch('firmware/companion.bin',{cache:'no-store'});requireThat(imageResponse.ok,'配布イメージを取得できません。');
 firmware=await verifyRelease(await imageResponse.arrayBuffer(),manifest);
 $('release').textContent=`C100 Companion · ${manifest.sourceCommit.slice(0,8)} · ${firmware.byteLength.toLocaleString()} bytes · SHA-256 確認済み`;
 log(`配布 SHA-256: ${manifest.sha256}`);
}catch(error){firmware=null;$('release').textContent=`書き込み不可: ${error.message||error}`;}update();})();
