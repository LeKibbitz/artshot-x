import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

if (process.platform !== 'darwin') throw new Error('Run this packaging script on macOS.');
const desktop = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const root = resolve(desktop, '..');
const config = JSON.parse(readFileSync(join(desktop, 'src-tauri/tauri.conf.json'), 'utf8'));
const app = join(root, 'target/release/bundle/macos', `${config.productName}.app`);
const run = (tool, args) => execFileSync(tool, args, { cwd: desktop, stdio: 'inherit' });
if (!process.argv.includes('--skip-build')) run('npm', ['run', 'tauri', '--', 'build', '--bundles', 'app']);
if (!existsSync(app)) throw new Error(`Missing application bundle: ${app}`);
const plist = join(app, 'Contents/Info.plist');
const version = execFileSync('/usr/libexec/PlistBuddy', ['-c', 'Print :CFBundleShortVersionString', plist], { encoding: 'utf8' }).trim();
if (version !== config.version) throw new Error('Application version differs from the packaging configuration.');
// Ad-hoc signing seals resources for local previews; it is not Developer ID signing or notarization.
const identity = process.env.ARTSHOT_SIGNING_IDENTITY || '-';
run('codesign', ['--force', '--sign', identity, join(app, 'Contents/Resources/bin/artshot-native')]);
run('codesign', ['--force', '--deep', '--sign', identity, app]);
run('codesign', ['--verify', '--deep', '--strict', app]);
const dist = join(root, 'dist');
mkdirSync(dist, { recursive: true });
const output = join(dist, `ArtShot-X-${version}-macOS-${process.arch}.dmg`);
const stage = mkdtempSync(join(tmpdir(), 'artshot-dmg-'));
try {
  run('ditto', [app, join(stage, `${config.productName}.app`)]);
  symlinkSync('/Applications', join(stage, 'Applications'));
  // No Finder/AppleScript layout step: the disk image builds unattended.
  run('hdiutil', ['create', '-ov', '-volname', `${config.productName} ${version}`, '-srcfolder', stage, '-format', 'UDZO', output]);
  run('hdiutil', ['verify', output]);
} finally {
  rmSync(stage, { recursive: true, force: true });
}
console.log(`Installer: ${output}`);
console.log(`SHA-256: ${createHash('sha256').update(readFileSync(output)).digest('hex')}`);
