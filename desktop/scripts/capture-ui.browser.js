// Run with the Playwright browser_run_code tool (filename), with Vite on :1420.
async (page) => {
  const assert = (ok, message) => { if (!ok) throw new Error(message); };
  async function open(label, width, height, selection = null) {
    await page.setViewportSize({ width, height });
    await page.addInitScript(({ label, selection }) => {
      const image = 'data:image/svg+xml,' + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="100" height="2000"><rect width="100" height="2000" fill="purple"/></svg>');
      window.commands = [];
      window.mockState = { library: [{ id: 'one', name: 'Capture', kind: 'image', path: image, createdAt: '2026-01-01' }], selection, settings: {}, selectionDisplay: { id: 'display', scaleFactor: 1, backgroundPath: image }, scrolling: { acceptedFrames: 3, status: 'Capturing', previewPath: image } };
      let id = 0;
      const callbacks = new Map();
      window.emitState = (state) => { window.mockState = state; for (const cb of callbacks.values()) cb({ payload: state }); };
      window.__TAURI_EVENT_PLUGIN_INTERNALS__ = { unregisterListener() {} };
      window.__TAURI_INTERNALS__ = {
        metadata: { currentWindow: { label }, currentWebview: { label } },
        transformCallback(cb) { callbacks.set(++id, cb); return id; },
        convertFileSrc(path) { return path; },
        async invoke(command, args) {
          window.commands.push({ command, args });
          if (command === 'plugin:event|listen') return args.handler;
          if (command === 'get_state') return window.mockState;
          if (command === 'set_selection') { await new Promise(resolve => setTimeout(resolve, 30)); window.commands.push({ command: 'set_selection_completed' }); }
        }
      };
    }, { label, selection });
    await page.goto('http://127.0.0.1:1420');
    await page.waitForFunction(() => window.commands.some(c => c.command === 'get_state'));
  }
  await open('quick', 340, 260);
  for (const name of ['Supprimer', 'Modifier', 'Enregistrer', 'Copier']) {
    const button = page.getByRole('button', { name, exact: true });
    const box = await button.boundingBox();
    assert(box && box.x >= 0 && box.y >= 0 && box.x + box.width <= 340 && box.y + box.height <= 260, `${name} outside quick window`);
    await button.click();
  }
  assert(await page.evaluate(() => ['delete_item', 'open_editor', 'save_item', 'copy_image'].every(command => window.commands.some(c => c.command === command && c.args.id === 'one'))), 'Quick actions must invoke real item commands');
  await page.evaluate(() => window.emitState({ ...window.mockState, error: 'Capture refusée' }));
  await page.getByRole('alert').waitFor();
  assert(await page.locator('.quick img').count() === 0, 'Capture error must not present an old image as a new capture');
  await open('scrolling', 350, 600);
  await page.getByRole('status').filter({ hasText: '3 images' }).waitFor();
  const imageBox = await page.locator('.scroll-window img').boundingBox();
  assert(imageBox && imageBox.y + imageBox.height <= 600, 'Full scrolling preview must fit');
  await page.getByRole('button', { name: 'Annuler', exact: true }).click();
  assert(await page.evaluate(() => window.commands.some(c => c.command === 'close_overlay')), 'Cancel must close scroll overlay');
  await open('scrolling', 280, 440);
  for (const name of ['Terminer', 'Annuler']) {
    const box = await page.getByRole('button', { name, exact: true }).boundingBox();
    assert(box && box.x >= 0 && box.x + box.width <= 280 && box.y + box.height <= 440, `${name} outside compact scroll window`);
  }
  const compactImage = await page.locator('.scroll-window img').boundingBox();
  assert(compactImage && compactImage.height > 0 && compactImage.y + compactImage.height <= 440, 'Compact scroll preview must fit');
  await open('selection', 1200, 800);
  await page.getByRole('button', { name: 'Écran', exact: true }).waitFor();
  assert(await page.getByRole('button', { name: 'Photo', exact: true }).isDisabled(), 'Photo must require a valid region');
  await page.mouse.move(100, 100); await page.mouse.down(); await page.mouse.move(500, 400); await page.mouse.up();
  await page.getByRole('button', { name: 'Photo', exact: true }).click();
  await page.waitForFunction(() => window.commands.some(c => c.command === 'capture_photo'));
  assert(await page.evaluate(() => { const commands = window.commands.map(c => c.command); const photo = commands.indexOf('capture_photo'); return photo > 0 && commands[photo - 1] === 'set_selection_completed'; }), 'Capture must await latest region');
  await page.mouse.move(700, 100); await page.mouse.down();
  assert(await page.locator('.selection-rect').count() === 0, 'New gesture must discard the old region immediately');
  await page.mouse.up();
  assert(await page.getByRole('button', { name: 'Photo', exact: true }).isDisabled(), 'Click without drag cannot capture the prior region');
  await page.evaluate(() => window.emitState({ ...window.mockState, selection: null, selectionDisplay: { ...window.mockState.selectionDisplay, backgroundPath: 'data:image/svg+xml,new-session' } }));
  await page.waitForFunction(() => !document.querySelector('.selection-rect'));
  assert(await page.getByRole('button', { name: 'Photo', exact: true }).isDisabled(), 'New session must clear region');
  return 'Passed: quick action visibility/commands; scrolling preview/status/cancel; selection toolbar, capture ordering, session reset';
}
