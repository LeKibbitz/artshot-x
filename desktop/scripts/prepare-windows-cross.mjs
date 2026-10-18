import { createRequire } from 'node:module';
import { dirname,resolve,join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mkdirSync,writeFileSync,readFileSync,copyFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { gunzipSync } from 'node:zlib';
const require=createRequire(import.meta.url);
const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const root=join(desktop,'src-tauri/resources/windows');
mkdirSync(join(root,'bin'),{recursive:true});mkdirSync(join(root,'licenses'),{recursive:true});
const base='https://github.com/eugeneware/ffmpeg-static/releases/download/b6.0/';
async function download(name){const response=await fetch(base+name);if(!response.ok)throw new Error(`Download ${name}: ${response.status}`);return Buffer.from(await response.arrayBuffer())}
const executable=gunzipSync(await download('ffmpeg-win32-x64.gz'));
const expected='e9fd5e711debab9d680955fc1e38a2c1160fd280b144476cc3f62bc43ef49db1';
const sha=buffer=>createHash('sha256').update(buffer).digest('hex');
if(sha(executable)!==expected)throw new Error('Pinned Windows FFmpeg SHA-256 mismatch');
function inspect(buffer,name){const strings=buffer.toString('latin1').match(/[ -~]{20,}/g)??[];const config=strings.filter(s=>s.startsWith('--enable-gpl')).sort((a,b)=>b.length-a.length)[0];if(!config)throw new Error(`${name}: cannot inspect build configuration`);if(config.includes('--enable-nonfree'))throw new Error(`${name} is nonredistributable`);return config}
const config=inspect(executable,'FFmpeg');writeFileSync(join(root,'bin/ffmpeg.exe'),executable);
for(const suffix of ['LICENSE','README'])writeFileSync(join(root,`licenses/ffmpeg.${suffix}`),await download(`win32-x64.${suffix}`));
writeFileSync(join(root,'licenses/ffmpeg-build-info.txt'),`ffmpeg-static 5.2.0 / binary release b6.0 / win32-x64\nBinary: ${base}ffmpeg-win32-x64.gz\nSHA-256 (decompressed): ${expected}\nConfiguration inspected from PE strings on macOS; Windows runtime not executed.\n${config}\nSource/build scripts: https://github.com/eugeneware/ffmpeg-static/tree/b6.0\nCorresponding source: https://ffmpeg.org/releases/ffmpeg-6.0.tar.xz\n`);
const probeDir=dirname(require.resolve('ffprobe-static/package.json'));const probe=readFileSync(join(probeDir,'bin/win32/x64/ffprobe.exe'));const probeConfig=inspect(probe,'FFprobe');writeFileSync(join(root,'bin/ffprobe.exe'),probe);copyFileSync(join(probeDir,'LICENSE'),join(root,'licenses/ffprobe-static.LICENSE'));
writeFileSync(join(root,'licenses/ffprobe-build-info.txt'),`ffprobe-static 3.1.0 / FFmpeg 4.0.2 / win32-x64\nSHA-256: ${sha(probe)}\nConfiguration inspected from PE strings on macOS; Windows runtime not executed.\n${probeConfig}\nPackage source: https://github.com/joshwnj/ffprobe-static\nCorresponding source: https://ffmpeg.org/releases/ffmpeg-4.0.2.tar.xz\nOriginal binary provider Zeranoe is discontinued. FFprobe executable is GPL, package wrapper license is MIT. Full GPL v3 accompanies FFmpeg in ffmpeg.LICENSE.\n`);
console.log(`Windows resources prepared. FFmpeg ${expected}; FFprobe ${sha(probe)}`);
