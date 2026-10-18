import { createRequire } from 'node:module';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mkdirSync, readdirSync, copyFileSync, chmodSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
const require = createRequire(import.meta.url);
const desktop = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const root = resolve(desktop, '..');
const resources = join(desktop, 'src-tauri/resources');
const bin = join(resources, 'bin');
const licenses = join(resources, 'licenses');
mkdirSync(bin, { recursive: true });
mkdirSync(licenses, { recursive: true });
if (process.platform === 'darwin') {
  const source = join(root, 'crates/artshot-platform/native/macos');
  const files = readdirSync(source).filter(name => name.endsWith('.swift')).sort().map(name => join(source, name));
  const arch = process.arch === 'arm64' ? 'arm64' : 'x86_64';
  console.log(`Compiling macOS 14+ bridge (${arch})…`);
  execFileSync('xcrun', ['swiftc', '-O', '-parse-as-library', '-target', `${arch}-apple-macosx14.0`, ...files, '-Xlinker', '-sectcreate', '-Xlinker', '__TEXT', '-Xlinker', '__info_plist', '-Xlinker', join(source, 'Info.plist'), '-o', join(bin, 'artshot-native')], { stdio: 'inherit' });
}
if (!['darwin', 'win32'].includes(process.platform)) throw new Error('Packaging supports macOS and Windows only.');
if (process.platform === 'darwin') {
  for (const name of ['ffmpeg-static.LICENSE', 'ffmpeg.LICENSE', 'ffmpeg.README', 'ffmpeg-build-info.txt', 'ffmpeg-source-info.txt']) rmSync(join(licenses, name), { force: true });
  rmSync(join(bin, 'ffmpeg'), { force: true });
  console.log('Prepared macOS native bridge. FFmpeg is not bundled; AVFoundation handles media.');
  process.exit(0);
}
const packageDir = dirname(require.resolve('ffmpeg-static/package.json'));
const packageInfo = JSON.parse(readFileSync(join(packageDir, 'package.json'), 'utf8'));
const binary = process.env.ARTSHOT_FFMPEG_PATH || require('ffmpeg-static');
if (!binary || !existsSync(binary)) throw new Error('FFmpeg missing. Run npm ci without --ignore-scripts or set ARTSHOT_FFMPEG_PATH.');
const version = execFileSync(binary, ['-version'], { encoding: 'utf8' });
const license = execFileSync(binary, ['-L'], { encoding: 'utf8' });
const sha256 = createHash('sha256').update(readFileSync(binary)).digest('hex');
for (const [source, target] of [['LICENSE', 'ffmpeg-static.LICENSE'], ['ffmpeg.LICENSE', 'ffmpeg.LICENSE'], ['ffmpeg.README', 'ffmpeg.README']]) {
  if (existsSync(join(packageDir, source))) copyFileSync(join(packageDir, source), join(licenses, target));
}
writeFileSync(join(licenses, 'ffmpeg-build-info.txt'), `Source package: ffmpeg-static ${packageInfo.version}\nBinary release: ${packageInfo['ffmpeg-static']['binary-release-tag']}\nBinary provider: ${process.env.ARTSHOT_FFMPEG_PATH ? 'ARTSHOT_FFMPEG_PATH override; see external-source-info.txt' : 'https://github.com/eugeneware/ffmpeg-static/releases/tag/b6.0'}\nPlatform: ${process.platform}-${process.arch}\nSHA-256: ${sha256}\n\n${version}\n${license}`);
writeFileSync(join(licenses, 'ffmpeg-source-info.txt'), `FFmpeg source: https://ffmpeg.org/releases/ffmpeg-6.0.tar.xz\nBinary build scripts and patches: https://github.com/eugeneware/ffmpeg-static/tree/b6.0\nBuild source archive: https://github.com/eugeneware/ffmpeg-static/archive/refs/tags/b6.0.tar.gz\nThe full configuration and actual license text are recorded in ffmpeg-build-info.txt.\nFor an override binary, provide its exact source/build instructions in external-source-info.txt.\n`);
if (version.includes('--enable-nonfree')) throw new Error('FFmpeg has --enable-nonfree and is not redistributable. Provide a redistributable build with ARTSHOT_FFMPEG_PATH.');
if (process.env.ARTSHOT_FFMPEG_PATH && !existsSync(join(licenses, 'external-source-info.txt'))) throw new Error('Override FFmpeg requires resources/licenses/external-source-info.txt with exact source and build instructions.');
const destination = join(bin, process.platform === 'win32' ? 'ffmpeg.exe' : 'ffmpeg');
copyFileSync(binary, destination);
if (process.platform !== 'win32') chmodSync(destination, 0o755);
console.log(`Prepared native resources (${process.platform}-${process.arch}), FFmpeg SHA-256 ${sha256}.`);
const probePackageDir = dirname(require.resolve('ffprobe-static/package.json'));
const probe = require('ffprobe-static').path;
const probeVersion = execFileSync(probe, ['-version'], { encoding: 'utf8' });
const probeLicense = execFileSync(probe, ['-L'], { encoding: 'utf8' });
if (probeVersion.includes('--enable-nonfree')) throw new Error('FFprobe has --enable-nonfree and cannot be bundled.');
copyFileSync(probe, join(bin, 'ffprobe.exe'));
copyFileSync(join(probePackageDir, 'LICENSE'), join(licenses, 'ffprobe-static.LICENSE'));
writeFileSync(join(licenses, 'ffprobe-build-info.txt'), `Source package: ffprobe-static 3.1.0\nUpstream binary provider: Zeranoe (discontinued)\nPackage source: https://github.com/joshwnj/ffprobe-static\nFFmpeg source: https://ffmpeg.org/releases/ffmpeg-4.0.2.tar.xz\nSHA-256: ${createHash('sha256').update(readFileSync(probe)).digest('hex')}\n\n${probeVersion}\n${probeLicense}`);
