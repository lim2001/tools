// Optional PTY terminal backend. Install @xterm/headless outside the repository,
// then pass its module directory to easyCmd_pty.py --xterm-headless.
const readline = require('node:readline');
const { Terminal } = require(process.argv[2]);
let terminal;
let emitted = [];
const input = readline.createInterface({ input: process.stdin });
async function handle(request) {
  emitted = [];
  let sent;
  switch (request.op) {
    case 'init':
      terminal = new Terminal({ cols: request.cols, rows: request.rows, allowProposedApi: true });
      terminal.onData(data => emitted.push(data));
      break;
    case 'write':
      await new Promise(resolve => terminal.write(Buffer.from(request.data, 'base64'), resolve));
      break;
    case 'resize':
      terminal.resize(request.cols, request.rows);
      break;
    case 'mouse':
      // Headless has no DOM. Exercise xterm's actual protocol/encoding service,
      // which only emits mouse input when the application has enabled tracking.
      sent = terminal._core.coreMouseService.triggerMouseEvent({
        col: request.x - 1, row: request.y - 1, button: request.button,
        action: request.release ? 0 : 1, ctrl: false, alt: false, shift: false
      });
      break;
  }
  const buffer = terminal.buffer.active;
  return {
    data: emitted, sent,
    mouse: terminal.modes.mouseTrackingMode,
    encoding: terminal._core.coreMouseService.activeEncoding,
    hidden: terminal._core.coreService.isCursorHidden,
    cells: Array.from({ length: terminal.rows }, (_, y) => {
      const line = buffer.getLine(buffer.viewportY + y);
      return Array.from({ length: terminal.cols }, (_, x) => {
        const cell = line.getCell(x);
        return [cell.getChars(), cell.getFgColor(), cell.getBgColor()];
      });
    }),
    cursor: [buffer.cursorY, buffer.cursorX],
    lines: Array.from({ length: terminal.rows }, (_, y) => buffer.getLine(buffer.viewportY + y)?.translateToString(false) ?? '')
  };
}
(async () => {
  for await (const line of input) {
    try { process.stdout.write(JSON.stringify(await handle(JSON.parse(line))) + '\n'); }
    catch (error) { process.stdout.write(JSON.stringify({ error: String(error) }) + '\n'); }
  }
  terminal?.dispose();
})();
