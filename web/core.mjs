export const BASE = 0x08000000;
export const SIZE = 262144;
export function requireThat(value, message) { if (!value) throw new Error(message); }
export function validateMemory(memory) {
  let end = BASE;
  requireThat(memory?.segments?.length, '内部フラッシュの情報を取得できません。');
  for (const s of memory.segments) {
    requireThat(s.start === end && s.end > s.start && s.readable && s.writable && s.erasable && Number.isInteger(s.sectorSize) && s.sectorSize > 0 && (s.end-s.start)%s.sectorSize === 0, '対応する内部フラッシュ構成ではありません。');
    end = s.end;
  }
  requireThat(end === BASE + SIZE, '256 KiB の対象以外には書き込めません。');
}
export async function sha256(bytes) {
  return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)), b => b.toString(16).padStart(2, '0')).join('');
}
export function equal(a,b) { return a.byteLength === b.byteLength && new Uint8Array(a).every((v,i)=>v === new Uint8Array(b)[i]); }
export function payload(image) {
  const b = new Uint8Array(image), n = b.length;
  requireThat(n > 16 && n <= SIZE+16 && b[n-8]===85 && b[n-7]===70 && b[n-6]===68 && b[n-5]===16, 'DFU suffix またはサイズが不正です。');
  // Dfu suffix CRC is an uncomplemented reflected CRC-32.
  let crc = 0xffffffff;
  for (const byte of b.subarray(0,n-4)) { crc ^= byte; for(let bit=0;bit<8;bit++) crc = (crc>>>1)^((crc&1)?0xedb88320:0); }
  requireThat((crc>>>0) === new DataView(image).getUint32(n-4,true), 'DFU CRC が一致しません。');
  return image.slice(0,-16);
}
export async function verifyRelease(image, manifest) {
  requireThat(manifest.model === 'keychron/c100_8k' && manifest.bytes === image.byteLength && /^[a-f0-9]{64}$/.test(manifest.sha256), '配布情報が不正です。');
  requireThat(await sha256(image) === manifest.sha256, '配布イメージの SHA-256 が一致しません。');
  return payload(image);
}
// Keep the device in DFU throughout writing and verification. No manifestation
// occurs here; the user requests the separate restart only after comparison.
export async function writeVerified(device, data, transferSize, progress = ()=>{}) {
  requireThat(data.byteLength > 0 && data.byteLength <= SIZE, '書き込みサイズが範囲外です。');
  requireThat(Number.isInteger(transferSize) && transferSize > 0 && transferSize <= 65535, '転送サイズが不正です。');
  await device.abortToIdle();
  await device.erase(BASE, data.byteLength);
  for(let offset=0;offset<data.byteLength;offset+=transferSize) {
    const chunk = data.slice(offset,offset+transferSize);
    await device.dfuseCommand(0x21, BASE+offset, 4);
    const written = await device.download(chunk,2);
    requireThat(written === chunk.byteLength, 'USB への書き込みが途中で終了しました。再起動せず復元してください。');
    const status = await device.poll_until_idle(5);
    requireThat(status.status === 0 && status.state === 5, 'DFU 書き込みエラーです。');
    progress(offset+written,data.byteLength);
  }
  const readback = await (await device.do_upload(transferSize,data.byteLength)).arrayBuffer();
  requireThat(equal(data,readback), '読み戻しが一致しません。再起動せず、バックアップから復元してください。');
}
