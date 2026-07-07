// Audit verify core — ONE TRUTH for AUDIT_RESULT_V1 encoding + Level-A reproduction.
// Shared verbatim by verify.mjs (node CLI) and verify-browser.mjs (in-tab button).
// Zero dependencies; pure JS keccak + ABI encoder + fetch RPC. No wallet, read-only.
//
// Honest limit (state wherever results are shown): this re-derives the ENCODING and the
// binding to live bytecode — not the EVM execution (Level B needs the harness / an EVM fork).

// ---------- keccak256 (pure JS, validated: keccak("")=c5d2…a470, keccak("abc")=4e03…6c45) ----------
const M=(1n<<64n)-1n;
const RC=[0x1n,0x8082n,0x800000000000808An,0x8000000080008000n,0x808Bn,0x80000001n,0x8000000080008081n,0x8000000000008009n,0x8An,0x88n,0x80008009n,0x8000000An,0x8000808Bn,0x800000000000008Bn,0x8000000000008089n,0x8000000000008003n,0x8000000000008002n,0x8000000000000080n,0x800An,0x800000008000000An,0x8000000080008081n,0x8000000000008080n,0x80000001n,0x8000000080008008n];
const RHO=[0,1,62,28,27,36,44,6,55,20,3,10,43,25,39,41,45,15,21,8,18,2,61,56,14];
const rot=(x,n)=>n===0n?x:((x<<n)|(x>>(64n-n)))&M;
export function keccak(input){let S=new Array(25).fill(0n);const rate=136;const len=input.length,pl=Math.ceil((len+1)/rate)*rate;const p=new Uint8Array(pl);p.set(input);p[len]^=1;p[pl-1]^=0x80;
 for(let o=0;o<pl;o+=rate){for(let i=0;i<rate/8;i++){let l=0n;for(let j=0;j<8;j++)l|=BigInt(p[o+i*8+j])<<(8n*BigInt(j));S[i]^=l;}
  for(let r=0;r<24;r++){const C=[0,1,2,3,4].map(x=>S[x]^S[x+5]^S[x+10]^S[x+15]^S[x+20]);const D=[0,1,2,3,4].map(x=>C[(x+4)%5]^rot(C[(x+1)%5],1n));for(let x=0;x<5;x++)for(let y=0;y<5;y++)S[x+5*y]^=D[x];const B=new Array(25).fill(0n);for(let x=0;x<5;x++)for(let y=0;y<5;y++)B[y+5*((2*x+3*y)%5)]=rot(S[x+5*y],BigInt(RHO[x+5*y]));for(let x=0;x<5;x++)for(let y=0;y<5;y++)S[x+5*y]=B[x+5*y]^((~B[(x+1)%5+5*y])&B[(x+2)%5+5*y])&M;S[0]^=RC[r];}}
 const out=new Uint8Array(32);for(let i=0;i<4;i++){let l=S[i];for(let j=0;j<8;j++)out[i*8+j]=Number((l>>(8n*BigInt(j)))&0xffn);}return out;}

// ---------- helpers ----------
const TE=new TextEncoder();
export const hx=u=>"0x"+[...u].map(b=>b.toString(16).padStart(2,"0")).join("");
export const fromHex=h=>{h=h.replace(/^0x/,"");if(h.length%2)h="0"+h;const a=new Uint8Array(h.length/2);for(let i=0;i<a.length;i++)a[i]=parseInt(h.substr(i*2,2),16);return a;};
const cat=a=>{const n=a.reduce((s,x)=>s+x.length,0),o=new Uint8Array(n);let p=0;for(const x of a){o.set(x,p);p+=x.length;}return o;};
export const w=()=>new Uint8Array(32);
export const u256=v=>{const b=w();let x=BigInt(v);for(let i=31;i>=0;i--){b[i]=Number(x&0xffn);x>>=8n;}return b;};
const b32=h=>{const u=fromHex(h),b=w();b.set(u,32-u.length);return b;};
const padR=u=>{const b=new Uint8Array(Math.ceil(u.length/32)*32);b.set(u);return b;};
const id=s=>keccak(TE.encode(s));
function abiEncode(types,vals){const heads=[],tails=[];const headSize=32*types.length;let off=headSize;
 const enc=[];
 for(let i=0;i<types.length;i++){const t=types[i],v=vals[i];
  if(t==="string"){const d=TE.encode(v);enc.push({dyn:true,bytes:cat([u256(d.length),padR(d)])});}
  else if(t==="bytes32[]"){enc.push({dyn:true,bytes:cat([u256(v.length),...v.map(b32)])});}
  else if(t==="bytes32")enc.push({dyn:false,bytes:b32(v)});
  else if(t==="address"){const u=fromHex(v),b=w();b.set(u,32-u.length);enc.push({dyn:false,bytes:b});}
  else if(t==="bool")enc.push({dyn:false,bytes:u256(v?1:0)});
  else enc.push({dyn:false,bytes:u256(v)});}
 for(const e of enc){if(e.dyn){heads.push(u256(off));tails.push(e.bytes);off+=e.bytes.length;}else heads.push(e.bytes);}
 return cat([...heads,...tails]);}
const kabi=(t,v)=>hx(keccak(abiEncode(t,v)));
export const eq=(a,b)=>String(a).toLowerCase()===String(b).toLowerCase();

// ---------- canonical spec constants (RealDeal/notebook/specs/withdraw-credits-v1.md, tool v1.1.0 L-02) ----------
const TOOL_ARTIFACT_HASH="0x630e81f397d999d092e086f66d93af2828eed69363e37dc1cca6395c5670c2c7";
export const FIX=10n**18n; // FIXTURE_AMOUNT = 1 ether
export const toolId=kabi(["bytes32","string","string","bytes32","string"],[hx(id("AUDIT_TOOL_V1")),"withdraw-credits","1.1.0",TOOL_ARTIFACT_HASH,"encodeResult(address,uint256,uint256)"]);
const INV=hx(id("INVARIANT_WITHDRAW_DECREMENTS_CREDITS_V1"));
const invRoot=kabi(["bytes32","bytes32[]"],[hx(id("AUDIT_INVARIANTS_V1")),[INV]]);
export const specHash=kabi(["bytes32","bytes32","uint256","bytes32"],[hx(id("AUDIT_SPEC_V1")),hx(id("genesis.spec.withdraw-credits.v1")),1n,invRoot]);
const tcr=kabi(["address","uint256","uint256"],["0x00000000000000000000000000000000000000B0",FIX,FIX]);
export const contextRoot=kabi(["bytes32","string","string","uint256","bool","bytes32","bytes32"],[hx(id("AUDIT_CONTEXT_V1")),"0.8.20","cancun",1n,true,tcr,hx(w())]);
const LOC=kabi(["string","string","string"],["withdraw(uint256)","credits[msg.sender]","missing-post-decrement"]);
export const PUBLISHED={toolId:"0xd485f0578dcf1925aa28cfb312584a4a172c4f5da7f05bde4c078c992b598456",specHash:"0x7fe57aec3c363ab9da26d8a45f6bd22f30a5f441b597136e9b8fbcdca38fbe77",contextRoot:"0x52c6c0ad349e991a23a9abf6f7e6400f1c1d85ae811e0657a2550b644103f74a",artifactHash:"0xc23bec99a1b30547fc6a0ea5ba54d64c81c02426731382b5146668ec5a43e520",failRoot:"0x7cf37a76774ebe9858d76408ca29ddb86562166e71b6422095e1b41e27dfd140"};

export function resultRoot(art,verdict,findings){return kabi(["bytes32","bytes32","bytes32","bytes32","bytes32","uint8","bytes32"],[hx(id("AUDIT_RESULT_V1")),toolId,art,specHash,contextRoot,verdict,findings]);}
export function failFindings(post){const witness=kabi(["uint256","uint256"],[FIX,post]);const leaf=kabi(["bytes32","bytes32","bytes32"],[INV,LOC,witness]);return kabi(["bytes32","bytes32[]"],[hx(id("AUDIT_FINDINGS_V1")),[leaf]]);}

// ---------- self-test rows (encoding correctness vs published canonical values) ----------
export function selfTestRows(){
  return [
    ["toolId",toolId,PUBLISHED.toolId],
    ["specHash",specHash,PUBLISHED.specHash],
    ["contextRoot",contextRoot,PUBLISHED.contextRoot],
    ["resultRoot(#7 FAIL)",resultRoot(PUBLISHED.artifactHash,0n,failFindings(FIX)),PUBLISHED.failRoot],
  ].map(([name,got,exp])=>({name,got,exp,ok:eq(got,exp)}));
}

// ---------- RPC ----------
export async function rpc(url,method,params){const r=await fetch(url,{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({jsonrpc:"2.0",id:1,method,params})});const j=await r.json();if(j.error)throw new Error(method+": "+JSON.stringify(j.error));return j.result;}
export const selector=sig=>hx(keccak(TE.encode(sig)).slice(0,4));

// ---------- Level-A reproduction (structured; callers render) ----------
export async function reproduce({rpcUrl="https://sepolia.base.org",cell,auditId,target}){
  const selfTest=selfTestRows();
  if(selfTest.some(r=>!r.ok))return{ok:false,stage:"self-test",selfTest};
  const code=await rpc(rpcUrl,"eth_getCode",[target,"latest"]);
  if(code==="0x")return{ok:false,stage:"target",selfTest,error:"target has no code (not a contract / wrong chain)"};
  const artifactHash=hx(keccak(fromHex(code)));
  const rootPASS=resultRoot(artifactHash,1n,hx(w()));
  const rootFAIL=resultRoot(artifactHash,0n,failFindings(FIX)); // FAIL fixture for the no-decrement bug: post==pre==1e18
  const data=selector("auditProofHash(uint256)")+hx(u256(BigInt(auditId))).slice(2);
  const onchain=await rpc(rpcUrl,"eth_call",[{to:cell,data},"latest"]);
  const verdict=eq(onchain,rootPASS)?"PASS":eq(onchain,rootFAIL)?"FAIL":null;
  return{ok:true,stage:"done",selfTest,rpcUrl,cell,auditId:String(auditId),target,artifactHash,rootPASS,rootFAIL,onchain,verdict};
}
