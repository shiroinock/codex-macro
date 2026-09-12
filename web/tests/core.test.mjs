import test from 'node:test';
import assert from 'node:assert/strict';
import {BASE,SIZE,validateMemory,writeVerified,verifyRelease,sha256} from '../core.mjs';
const memory={segments:[{start:BASE,end:BASE+SIZE,sectorSize:2048,readable:true,writable:true,erasable:true}]};
test('only contiguous readable/writable 256 KiB internal flash accepted',()=>{
 validateMemory(memory);
 for(const patch of [{start:BASE+2048},{end:BASE+SIZE*2},{readable:false},{writable:false},{sectorSize:0}]) assert.throws(()=>validateMemory({segments:[{...memory.segments[0],...patch}]}));
 assert.throws(()=>validateMemory({segments:[]}));
});
function fake(data,{short=false,corrupt=false,error=false}={}){
 const calls=[];
 return {calls,abortToIdle:async()=>calls.push('idle'),erase:async(a,n)=>calls.push(['erase',a,n]),dfuseCommand:async(c,a)=>calls.push(['address',a]),download:async(chunk,block)=>{assert.equal(block,2);assert.ok(chunk.byteLength>0);calls.push('write');return short?0:chunk.byteLength;},poll_until_idle:async()=>({status:error?1:0,state:5}),do_upload:async(x,n)=>{calls.push('readback');return new Blob([corrupt?new Uint8Array(n):data]);}};
}
test('writes chunks then reads back, never manifests',async()=>{const data=new Uint8Array(19).fill(9).buffer,d=fake(data);await writeVerified(d,data,8);assert.equal(d.calls.filter(c=>c==='write').length,3);assert.equal(d.calls.at(-1),'readback');assert.deepEqual(d.calls[1],['erase',BASE,19]);});
test('short writes, DFU errors and corrupt readback stop completion',async()=>{const data=new Uint8Array(19).fill(9).buffer;for(const opts of [{short:true},{corrupt:true},{error:true}])await assert.rejects(writeVerified(fake(data,opts),data,8));});
test('out of range writes rejected before erase',async()=>{for(const bytes of [0,SIZE+1]){const data=new ArrayBuffer(bytes),d=fake(data);await assert.rejects(writeVerified(d,data,8));assert.equal(d.calls.length,0);}});
test('release hash and DFU suffix required',async()=>{const bytes=new Uint8Array(64).buffer;await assert.rejects(verifyRelease(bytes,{model:'keychron/c100_8k',bytes:64,sha256:await sha256(bytes)}));await assert.rejects(verifyRelease(bytes,{model:'other',bytes:64,sha256:await sha256(bytes)}));});
