import {BASE,validateMemory,requireThat} from './core.mjs';
export async function connectUSB(usb, log, progress) {
  const raw = await usb.requestDevice({filters:[{vendorId:0x2e3c,productId:0xdf11}]});
  try {
    requireThat(raw.vendorId===0x2e3c && raw.productId===0xdf11,'対象外の USB デバイスです。');
    const interfaces = dfu.findDeviceDfuInterfaces(raw).filter(i=>i.alternate.alternateSetting===0 && i.alternate.interfaceProtocol===2);
    requireThat(interfaces.length===1,'DFU 内部フラッシュを一意に選べません。');
    const settings=interfaces[0], reader=new dfu.Device(raw,settings);
    await raw.open();
    await raw.selectConfiguration(settings.configuration.configurationValue);
    if(!settings.name) {
      const names=await reader.readInterfaceNames();
      settings.name=names[settings.configuration.configurationValue][settings.interface.interfaceNumber][0];
    }
    const device=new dfuse.Device(raw,settings);
    validateMemory(device.memoryInfo);
    await device.open();
    const index=raw.configurations.findIndex(c=>c.configurationValue===settings.configuration.configurationValue);
    const config=dfu.parseConfigurationDescriptor(await device.readConfigurationDescriptor(index));
    const descriptors=config.descriptors.filter(d=>d.bDescriptorType===0x21 && d.bcdDFUVersion !== undefined);
    requireThat(descriptors.length===1,'DFU 機能情報を一意に取得できません。');
    const d=descriptors[0];
    requireThat(d.bcdDFUVersion===0x011a && (d.bmAttributes&3)===3 && d.wTransferSize>0 && d.wTransferSize<=65535,'読み書き可能な DfuSe デバイスではありません。');
    device.startAddress=BASE;
    device.logInfo=device.logWarning=log; device.logError=log; device.logDebug=()=>{}; device.logProgress=progress;
    // Upstream polling is unbounded. Stop on status errors or a stalled device.
    device.poll_until=async function(predicate) {
      const deadline=Date.now()+30000;
      while(Date.now()<deadline) {
        const status=await this.getStatus();
        requireThat(status.status===0 && status.state!==10,'DFU がエラー状態になりました。USB を接続し直してください。');
        if(predicate(status.state)) return status;
        requireThat(status.pollTimeout<=30000,'DFU の待機時間が範囲外です。');
        await new Promise(resolve=>setTimeout(resolve,Math.max(status.pollTimeout,10)));
      }
      throw new Error('DFU の応答がタイムアウトしました。');
    };
    const state=await device.getState();
    requireThat(state!==10,'DFU がエラー状態です。USB を接続し直してください。');
    await device.abortToIdle();
    return {device,transferSize:d.wTransferSize};
  } catch(error) { if(raw.opened) await raw.close().catch(()=>{}); throw error; }
}
