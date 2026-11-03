#!/usr/bin/env python3
"""PTY acceptance for history_fuzzy (requires Python 3, pyte, zsh and oh-my-zsh).

Run: python3 assist/tests/history_fuzzy_pty.py
Optional: --omz /path/to/oh-my-zsh --plugin /path/to/history_fuzzy.zsh
Use --mouse-only for mouse cases, --focused for native keys/Enter,
and --history-only for empty-input menus and PageUp/PageDown.
Each child uses an empty environment, a fresh HOME and a private plugin copy.
Only synthetic history is loaded. The PTY and terminal emulator share dimensions.
CPR replies come from the emulator's cursor, with separate no-response cases.
For xterm-generated clicks, pass --xterm-headless /path/to/@xterm/headless.
Raw terminal bytes, screen snapshots and results are kept in /tmp.
"""
import argparse
import base64
import subprocess
from types import SimpleNamespace
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pty
import re
import select
import shutil
import shlex
import signal
import struct
import sys
import tempfile
import termios
import time
import traceback

import pyte
from pyte.graphics import FG_BG_256

HOVER_BG = FG_BG_256[23]
HOVER_FG = FG_BG_256[255]
HOVER_MATCH = FG_BG_256[157]

def contrast(fg, bg):
    def luminance(color):
        rgb = [int(color[i:i+2], 16) / 255 for i in (0, 2, 4)]
        return sum(w * (v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4)
                   for w, v in zip((.2126, .7152, .0722), rgb))
    low, high = sorted((luminance(fg), luminance(bg)))
    return (high + .05) / (low + .05)

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--plugin', type=Path, default=Path(__file__).resolve().parents[1] / 'history_fuzzy.zsh')
parser.add_argument('--omz', type=Path, default=Path.home() / '.oh-my-zsh')
parser.add_argument('--history-only', action='store_true', help='only empty-input menu and PageUp/PageDown cases')
parser.add_argument('--mouse-only', action='store_true', help='only automatic mouse regressions')
parser.add_argument('--xterm-headless', type=Path, help='optional installed @xterm/headless directory')
parser.add_argument('--focused', action='store_true', help='only native key and Enter selection regressions')
args = parser.parse_args()
PLUGIN = str(args.plugin.resolve())
OMZ = str(args.omz.resolve())
if not Path(OMZ, 'oh-my-zsh.sh').is_file():
    parser.error('--omz must point to oh-my-zsh with vi-mode, autosuggestions and syntax-highlighting')
ARTIFACTS = Path(tempfile.mkdtemp(prefix='history-fuzzy-pty-'))
print('Evidence: ' + str(ARTIFACTS), flush=True)

class TerminalScreen(pyte.Screen):
    def report_device_status(self, mode, **kwargs):
        if mode == 6 and kwargs.get('private'):
            self.write_process_input(f'\x1b[?{self.cursor.y+1};{self.cursor.x+1}R')
        else:
            super().report_device_status(mode)


class Xterm:
    def __init__(self, cols, rows):
        self.proc = subprocess.Popen(['node', str(Path(__file__).with_name('history_fuzzy_xterm.cjs')),
                                      str(args.xterm_headless.resolve())],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.state = self.call(op='init', cols=cols, rows=rows)

    def call(self, **request):
        self.proc.stdin.write(json.dumps(request)+'\n')
        self.proc.stdin.flush()
        result=json.loads(self.proc.stdout.readline())
        assert 'error' not in result,result
        self.state=result
        return result

    def close(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=3)


class XtermScreen:
    # Use xterm's own screen and colors as the source of truth: its resize/reflow
    # behavior differs from pyte, so combining one engine's mouse rows with the
    # other's display would produce misleading acceptance results.
    palette = ('black','red','green','brown','blue','magenta','cyan','white',
               'brightblack','brightred','brightgreen','brightbrown',
               'brightblue','brightmagenta','brightcyan','brightwhite')
    blank = pyte.Screen(1,1).default_char

    def update(self, state):
        self.display = state['lines']
        self.cursor = SimpleNamespace(y=state['cursor'][0], x=state['cursor'][1], hidden=state['hidden'])
        self.mode = set()
        if state['mouse'] != 'none': self.mode.add(1000 << 5)
        if state['encoding'] == 'SGR': self.mode.add(1006 << 5)
        def color(n):
            return 'default' if n < 0 else self.palette[n] if n < 16 else FG_BG_256[n] if n < 256 else f'{n:06x}'
        self.buffer = {y: {x: self.blank._replace(data=c[0],fg=color(c[1]),bg=color(c[2]))
                           for x,c in enumerate(row)} for y,row in enumerate(state['cells'])}

    def resize(self, rows, cols):
        pass  # The bridge resizes the actual terminal and returns the resulting screen.


class Session:
    def __init__(self, rc, cols=100, rows=24, plugin=None, cpr=True):
        self.home = Path(tempfile.mkdtemp(prefix="case-", dir=ARTIFACTS))
        (self.home / ".zshrc").write_text(rc + r"""
# Wait for ZLE, not a fixed startup delay: Ctrl-C must never interrupt .zshrc.
for map in main viins vicmd; do bindkey -L -M $map > $HOME/$map.before; done
autoload -Uz add-zle-hook-widget
_hf_test_ready() { : > $HOME/ready; }
add-zle-hook-widget line-init _hf_test_ready
""")
        if plugin:
            shutil.copyfile(plugin, self.home / 'history_fuzzy.zsh')
        self.cols, self.rows = cols, rows
        self.screen = TerminalScreen(cols, rows)
        self.stream = pyte.ByteStream(self.screen)
        self.raw = bytearray()
        self.xterm = Xterm(cols, rows) if args.xterm_headless else None
        self.cpr = cpr
        if self.xterm:
            self.screen = XtermScreen()
            self.screen.update(self.xterm.state)
        pid, fd = pty.fork()
        if pid == 0:
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
            env = {"HOME": str(self.home), "ZDOTDIR": str(self.home),
                   "PATH": "/usr/local/bin:/usr/bin:/bin", "TERM": "xterm-256color",
                   "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "SHELL": "/usr/bin/zsh"}
            os.execve("/usr/bin/zsh", ["zsh", "-d", "-i"], env)
        self.pid, self.fd = pid, fd
        self.replies = []
        if cpr and not self.xterm:
            self.screen.write_process_input = self.reply
        deadline = time.monotonic() + 10
        while not (self.home/'ready').exists():
            self.read(.05)
            if time.monotonic() > deadline:
                self.close()
                raise AssertionError('shell did not finish initializing')
        self.read(.1)

    def reply(self, data):
        self.replies.append(data)
        os.write(self.fd, data.encode())

    def read(self, duration=.2):
        start = len(self.raw)
        deadline = time.monotonic() + duration
        while time.monotonic() < deadline:
            if select.select([self.fd], [], [], max(0, deadline-time.monotonic()))[0]:
                try:
                    data = os.read(self.fd, 65536)
                except OSError as e:
                    if e.errno == errno.EIO:
                        break
                    raise
                if not data:
                    break
                self.raw.extend(data)
                if not self.xterm:
                    self.stream.feed(data)
                if self.xterm:
                    state=self.xterm.call(op='write',data=base64.b64encode(data).decode())
                    self.screen.update(state)
                    for reply in state['data']:
                        if self.cpr:
                            self.reply(reply)
        return bytes(self.raw[start:])

    def send(self, data, delay=.2):
        os.write(self.fd, data.encode() if isinstance(data, str) else data)
        return self.read(delay)

    def mouse(self, button=0, x=4, y=1, release=False, delay=.2):
        if self.xterm:
            state=self.xterm.call(op='mouse',button=button,x=x,y=y,release=release)
            assert state['sent'] and state['data'], 'terminal did not forward the physical click'
            for data in state['data']:
                os.write(self.fd, data.encode())
        else:
            assert 1000 << 5 in self.screen.mode and 1006 << 5 in self.screen.mode
            os.write(self.fd, f"\x1b[<{button};{x};{y}{'m' if release else 'M'}".encode())
        return self.read(delay)

    def snapshot(self, label):
        result = {"label": label, "cursor": [self.screen.cursor.y, self.screen.cursor.x],
                  "lines": self.screen.display,
                  "selection_styles": sorted({(cell.fg, cell.bg)
                                              for row in self.screen.buffer.values()
                                              for cell in row.values() if cell.bg == HOVER_BG}),
                  "selected_rows": [y for y in range(self.rows)
                                if any(self.screen.buffer[y][x].bg == HOVER_BG for x in range(self.cols))]}
        (self.home / (label + ".json")).write_text(json.dumps(result, ensure_ascii=False, indent=2))
        return result

    def resize(self, cols, rows):
        self.cols, self.rows = cols, rows
        self.screen.resize(rows, cols)
        if self.xterm:
            self.screen.update(self.xterm.call(op='resize',cols=cols,rows=rows))
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        os.kill(self.pid, signal.SIGWINCH)
        self.read(.3)

    def close(self):
        (self.home / "terminal.raw").write_bytes(self.raw)
        os.kill(self.pid, signal.SIGTERM)
        os.close(self.fd)
        os.waitpid(self.pid, 0)
        if self.xterm:
            self.xterm.close()



BASE = r'''
HISTFILE=$HOME/history
HISTSIZE=10000
SAVEHIST=0
KEYTIMEOUT=10
autoload -Uz compinit
compinit -d $HOME/zcompdump
zmodload zsh/complist
zstyle ':completion:*' menu select
record() { print -r -- "$*" >> $HOME/executed; }
for n in {01..15}; do print -s -- "record MANUAL-$n"; done
for n in {01..15}; do print -s -- "echo sample-$n"; done
print -s -- 'echo 中文测试'
print -s -- 'echo 中文百分号%测试'
print -s -- 'echo aVeryLongHistoricalArgumentWithNoSpacesToTestWrapping01234567890123456789012345678901234567890123456789012345678901234567890123456789'
mkdir -p $HOME/completion
touch $HOME/completion/alpha $HOME/completion/alpine
cd $HOME/completion
probe() {
  print -r -- "$POSTDISPLAY" > $HOME/postdisplay
  print -r -- "$CURSOR" "$KEYMAP" "$_hist_fuzzy_hover" "${#_hist_fuzzy_shown}" "$COLUMNS" "$LINES" > $HOME/state
  print -rl -- "${region_highlight[@]}" > $HOME/highlights
  bindkey -L -M main > $HOME/main.after
  bindkey -L -M viins > $HOME/viins.after
  bindkey -L -M vicmd > $HOME/vicmd.after
  print -r -- "$BUFFER" > $HOME/buffer
}
zle -N _hf_probe probe
bindkey -M main '^X?' _hf_probe
bindkey -M viins '^X?' _hf_probe
bindkey -M vicmd '^X?' _hf_probe
bindkey -L -M main > $HOME/main.before
bindkey -L -M viins > $HOME/viins.before
bindkey -L -M vicmd > $HOME/vicmd.before
source $HOME/history_fuzzy.zsh
'''


def config(mode, extra=''):
    if mode == 'omz':
        start = f'''ZSH={shlex.quote(OMZ)}
ZSH_CACHE_DIR=$HOME/cache
ZSH_COMPDUMP=$HOME/zcompdump
DISABLE_AUTO_UPDATE=true
zstyle ':omz:update' mode disabled
ZSH_THEME=ys
plugins=(git vi-mode zsh-autosuggestions zsh-syntax-highlighting)
source $ZSH/oh-my-zsh.sh
'''
    else:
        start = 'bindkey -' + ('v' if mode == 'vi' else 'e') + '\n'
    return start + BASE + "\nPROMPT='hf> '\nRPROMPT=''\n" + extra


def probe(s):
    target=s.home/'buffer'
    previous=target.stat().st_mtime_ns if target.exists() else 0
    s.send(b'\x18?', .005)
    deadline=time.monotonic()+3
    while time.monotonic()<deadline:
        if target.exists() and target.stat().st_mtime_ns>previous:
            s.read(.15)
            return target.read_text().removesuffix('\n')
        s.read(.005)
    raise AssertionError('probe timed out')


def listed(s):
    return [(y, line.rstrip()) for y, line in enumerate(s.screen.display) if re.match(r'^\d\d ', line)]


def clean(s, data):
    # In native menu-select the first Ctrl-C cancels completion, restoring the
    # original input. Wait for an actual new ZLE line before typing the next case.
    ready = s.home / 'ready'
    previous = ready.stat().st_mtime_ns
    s.send(b'\x03', .08)
    if ready.stat().st_mtime_ns == previous:
        s.send(b'\x03', .08)
    deadline = time.monotonic() + 3
    while ready.stat().st_mtime_ns == previous:
        assert time.monotonic() < deadline, 'Ctrl-C did not start a fresh input line'
        s.read(.02)
    s.send(data, .15)


def check_hover(s, idx):
    rows = listed(s)
    assert len(rows) == 10, rows
    selected = [y for y in range(s.rows) if any(c.bg == HOVER_BG for c in s.screen.buffer[y].values())]
    assert selected == [rows[idx-1][0]], (idx, selected, rows)
    y = selected[0]
    cells = [s.screen.buffer[y][x] for x in range(len(rows[idx-1][1]))]
    glyphs = [cell for cell in cells if cell.data.strip()]
    assert {cell.fg for cell in glyphs} == {HOVER_FG, HOVER_MATCH}, glyphs
    assert all(contrast(cell.fg, cell.bg) >= 4.5 for cell in glyphs), 'low contrast selected text'
    assert all(s.screen.buffer[row][x].bg == 'default'
               for row, _ in rows if row != y for x in range(s.cols-1)), 'stale selection background'
    assert all(s.screen.buffer[y][x].bg == HOVER_BG for x in range(s.cols-1)), 'hover not full width'


def exercise(mode, cols):
    s = Session(config(mode), cols=cols, plugin=PLUGIN)
    checks = []
    try:
        assert not re.search(rb'(command not found|read-only|bad pattern|parse error|maximum nested|incompatible keymap)', s.raw), bytes(s.raw)
        s.send('record MANUAL')
        assert probe(s) == 'record MANUAL'
        state = (s.home/'state').read_text().split()
        assert state[-2:] == [str(cols), '24'], state
        checks.append('pty and pyte dimensions agree; no first printable key lost')
        check_hover(s, 1)
        before = list(s.screen.display)
        cursor = (s.screen.cursor.y, s.screen.cursor.x)
        for idx, key in [(2,b'\x1b[B'),(3,b'\x1b[B'),(2,b'\x1b[A'),(1,b'\x1b[A')]:
            raw = s.send(key, .12)
            check_hover(s, idx)
            assert s.screen.display == before, 'text moved on hover'
            assert (s.screen.cursor.y,s.screen.cursor.x) == cursor
            assert b'\x1b[2J' not in raw and b'\n' not in raw, 'hover cleared/scrolled screen'
        s.snapshot('hover')
        checks.append('CSI first arrow; down down up up; dark teal full row; selected text contrast >= 4.5:1; stable cursor/text; no scrolling')
        for key, idx in [(b'\x1bOB',2),(b'\x1bOA',1)]:
            s.send(key, .12)
            check_hover(s, idx)
        checks.append('SS3 arrows')
        rows = listed(s)
        assert all(s.screen.buffer[rows[1][0]][x].fg == 'green' for x in range(3,9))
        checks.append('matching characters green')
        executed = rows[2][1][3:].removeprefix('record ') + '\n'
        s.send(b'\x1b[B\x1b[B\r')
        assert (s.home/'executed').read_text() == executed, (s.home/'executed').read_text()
        assert not listed(s) and not s.snapshot('entered')['selected_rows']
        checks.append('Enter after explicit selection fills and executes selected item exactly once')
        s.send('record MANUAL\r')
        executed += 'MANUAL\n'
        assert (s.home/'executed').read_text() == executed
        assert not listed(s)
        checks.append('Enter without selection still executes typed BUFFER')
        for key, idx in [(b'\t',2),(b'\x1b[C',2),(b'\x1bOC',2)]+[(b'\x1b'+str(n).encode(),n) for n in range(1,10)]:
            clean(s, 'record MANUAL')
            expected = listed(s)[idx-1][1][3:]
            s.send(b'\x1b[B', .08)
            s.send(key, .12)
            assert probe(s) == expected, (key, expected, (s.home/'buffer').read_text())
            assert not listed(s)
            assert (s.home/'executed').read_text() == executed
        checks.append('Tab/right/Alt-1..9 fill exact full item, cursor at end, never execute')
        clean(s, 'echo')
        s.send(b'\x07')
        assert probe(s) == 'echo' and not listed(s)
        s.send(' s')
        assert listed(s)
        checks.append('Ctrl-G closes; normal input resumes')
        clean(s, 'echo')
        s.send(b'\x03')
        assert probe(s) == '' and not listed(s)
        s.send('echo s')
        assert listed(s)
        checks.append('Ctrl-C resets and next prompt works')
        clean(s, 'cat al')
        s.send(b'\t\t', .3)
        snap=s.snapshot('completion')
        assert 'alpha' in '\n'.join(snap['lines']) and 'alpine' in '\n'.join(snap['lines']), snap
        s.send(b'\x1b[B\t', .15)
        checks.append('native completion menu and selection')
        clean(s, 'echo')
        s.send(b'\x07')
        if mode == 'omz':
            rawpost=(s.home/'postdisplay')
            buf=probe(s)
            post=rawpost.read_text().removesuffix('\n')
            assert post and '\n' not in post, (buf,post)
            text='\n'.join(s.screen.display)
            assert 'sample-' in text or 'aVeryLong' in text or '中文' in text, text
            s.snapshot('suggestion')
            checks.append('autosuggestion survives list and dismissal')
        clean(s, 'zzzzNoMatch')
        assert not listed(s)
        assert probe(s)=='zzzzNoMatch'
        checks.append('no match leaves no residue')
        clean(s, 'echo 中文')
        assert len(listed(s)) >= 1
        s.snapshot('unicode')
        checks.append('wide characters')
        clean(s, 'echo aVeryLong')
        assert len(listed(s)) == 1
        assert listed(s)[0][1].endswith('…')
        s.send(b'\x1b1')
        assert len(probe(s)) > cols
        checks.append('long candidate clipped by cells; acceptance keeps complete command')
        if mode != 'emacs':
            clean(s, 'echo')
            s.send(b'\x1b', .25)
            assert not listed(s), listed(s)
            assert probe(s) == 'echo'
            assert (s.home/'state').read_text().split()[1] == 'vicmd'
            s.send('iX')
            assert 'X' in probe(s)
            checks.append('Esc retains vi-cmd-mode; i returns to insertion')
        probe(s)
        for keymap in ('main','viins','vicmd'):
            assert (s.home/(keymap+'.before')).read_bytes() == (s.home/(keymap+'.after')).read_bytes(), keymap
        checks.append('main/viins/vicmd bindings byte-for-byte unchanged')
        clean(s, 'record MANUAL\x1b[B\t')
        assert probe(s).startswith('record MANUAL-')
        assert (s.home/'executed').read_text() == executed
        checks.append('burst input + arrow + Tab uses current query')
        assert b'\x1b[6n' not in s.raw and b'\x1b[?6n' not in s.raw
        assert not re.search(rb'(command not found|read-only|bad pattern|parse error|maximum nested|incompatible keymap)', s.raw)
        checks.append('no DSR, errors, or stray list text in BUFFER')
        return {'mode': mode, 'size': [cols,24], 'pass': True, 'checks': checks, 'artifacts': str(s.home)}
    except Exception as e:
        s.snapshot('FAILED')
        return {'mode': mode, 'size': [cols,24], 'pass': False, 'error': traceback.format_exc(), 'checks': checks, 'artifacts': str(s.home)}
    finally:
        s.close()



matrix=[]
for mode in (() if args.focused or args.mouse_only or args.history_only else ('vi','emacs','omz')):
    for cols in (80,100):
        result=exercise(mode,cols)
        matrix.append(result)
        print(('PASS' if result['pass'] else 'FAIL') + f' {mode} {cols}x24', flush=True)

edge_results=[]
def run(name, mode, extra, test, cols=100, rows=24, cpr=True):
    if args.history_only and not name.startswith('history keys:'):
        return
    if args.mouse_only and not name.startswith('mouse:'):
        return
    if args.focused and not name.startswith(('native keys:', 'Enter selection:')):
        return
    s=Session(config(mode,extra), cols=cols, rows=rows, plugin=PLUGIN, cpr=cpr)
    try:
        detail=test(s)
        assert not re.search(rb'(command not found|read-only|bad pattern|parse error|maximum nested|incompatible keymap)', s.raw)
        edge_results.append(dict(name=name,passed=True,detail=detail,artifacts=str(s.home)))
    except Exception:
        s.snapshot('FAILED')
        edge_results.append(dict(name=name,passed=False,error=traceback.format_exc(),artifacts=str(s.home)))
    finally:s.close()
    print(('PASS' if edge_results[-1]['passed'] else 'FAIL') + ' ' + name, flush=True)

def empty(s):
    s.send('record');assert not listed(s)
    assert probe(s)=='record'
    s.send(b'\x07');assert not listed(s)
run('empty history','vi','fc -p $HOME/empty 0\n',empty)

def fifteen(s):
    s.send('record MANUAL');assert len(listed(s))==15
    s.snapshot('fifteen')
    s.send(b'\x1b[A');assert s.snapshot('wrap-up')['selected_rows']==[listed(s)[-1][0]]
run('15 results and navigation wrap','omz','HIST_FUZZY_MAX_SHOW=15\n',fifteen)

def resize(s):
    s.send('record MANUAL');assert len(listed(s))==10
    for cols,rows in ((80,24),(40,12),(25,8),(100,24)):
        s.resize(cols,rows)
        s.send(b'\x1b[B')
        b=probe(s)
        assert b=='record MANUAL',b
        assert 0 < len(listed(s)) <= min(10,rows-4), listed(s)
        selected=s.snapshot(f'resize-{cols}x{rows}')['selected_rows']
        assert len(selected)==1,selected
        assert all(s.screen.buffer[selected[0]][x].bg==HOVER_BG for x in range(cols-1))
run('terminal resize','omz','',resize)

def edit(s):
    s.send('echo sample');s.send(b'\x1b[D\x1b[DX')
    b=probe(s);assert b=='echo sampXle',b
    assert int((s.home/'state').read_text().split()[0])==10
    s.send(b'\x7f');assert probe(s)=='echo sample'
    clean(s,'\x1b[200~record MANUAL\x1b[201~')
    assert probe(s)=='record MANUAL'
    assert listed(s)
run('middle editing and bracketed paste','omz','',edit)

def original_accept(s):
    s.send('echo sample')
    s.send(b'\x05')  # OMZ end-of-line accepts its grey suggestion.
    b=probe(s)
    assert b=='echo sample-15',repr(b)
    assert '\n' not in b and '01 ' not in b
run('autosuggestion end-of-line never accepts list text','omz','',original_accept)

def theme(s):
    s.send('record MANUAL');assert len(listed(s))==10
    before=list(s.screen.display);cur=(s.screen.cursor.y,s.screen.cursor.x)
    for key in (b'\x1b[B',b'\x1b[B',b'\x1b[A',b'\x1b[A'):
        raw=s.send(key);assert s.screen.display==before
        assert (s.screen.cursor.y,s.screen.cursor.x)==cur
        assert b'\n' not in raw
    s.snapshot('ys-theme')
    s.send(b'\x03');assert not listed(s)
run('real ys multiline coloured prompt','omz',f'source {shlex.quote(OMZ + "/themes/ys.zsh-theme")}\n',theme)

def syntax(s):
    s.send('echo sample')
    y=s.screen.cursor.y
    assert s.screen.buffer[y][4].fg=='green',s.screen.buffer[y][4]
    suggestion=[s.screen.buffer[y][x] for x in range(15,18)]
    assert any(c.fg in ('brightblack','808080') for c in suggestion),suggestion
    s.snapshot('syntax-and-grey')
run('syntax green command and grey suggestion alongside list','omz','',syntax)

def burst_enter(s):
    s.send('record MANUAL\x1b[B\x1b[B\r')
    assert (s.home/'executed').read_text()=='MANUAL-13\n'
    assert not listed(s)
run('burst query + two arrows + Enter','omz','',burst_enter)

def special(s):
    s.send('echo *');rows=listed(s)
    assert len(rows)==1 and 'literal*star' in rows[0][1],rows
    s.send(b'\x1b1');assert probe(s)=='echo literal*star'
    clean(s,'echo percent');assert '100%' in listed(s)[0][1]
    s.send(b'\x1b1');assert probe(s)=='echo percent100%'
run('literal glob and percent','vi',"print -s -- 'echo literal*star'\nprint -s -- 'echo percent100%'\n",special)

def macro(s):
    s.send(b'\x1b1')
    assert probe(s)=='MACRO',repr(probe(s))
run('native Alt macro when list absent','vi',"bindkey -M main -s '\\e1' 'MACRO'\n",macro)

def bottom(s):
    s.send('record MANUAL')
    assert len(listed(s))==10
    before=list(s.screen.display);cur=(s.screen.cursor.y,s.screen.cursor.x)
    for key in (b'\x1b[B',b'\x1b[B',b'\x1b[A'):
        raw=s.send(key);assert s.screen.display==before
        assert (s.screen.cursor.y,s.screen.cursor.x)==cur
        assert b'\n' not in raw
    s.snapshot('bottom')
run('prompt at bottom, stable after list allocation','vi',"repeat 25 print -- retained-output\n",bottom)

def perf(s):
    timings=[]
    for char in 'git fet':
        start=time.monotonic()
        s.send(char,.005)
        query='git fet'[:len(timings)+1]
        assert probe(s)==query
        deadline=start+3
        while time.monotonic()<deadline:
            rows=listed(s)
            if len(rows)==10 and s.screen.buffer[rows[1][0]][2+len(query.rstrip())].fg=='green':
                break
            s.read(.005)
        assert len(listed(s))==10
        elapsed=(time.monotonic()-start)*1000
        timings.append(round(elapsed,2))
        assert elapsed<500,(char,elapsed)
    assert probe(s)=='git fet'
    return {'history':2200,'per_key_ms':timings,'max_ms':max(timings)}
run('2200 histories typing latency','omz',r'''
fc -p $HOME/perfhistory 5000
for n in {0001..2200}; do print -s -- "git fetch repo-$n --branch feature-$n"; done
''',perf)

NATIVE_HISTORY = r'''
print -s -- 'record PRIORITY-s'
print -s -- 'record PRIORITY-medium'
print -s -- 'record PRIORITY-most-recent-long'
print -s -- 'cat alphabet-from-history'
'''
NATIVE_TAB = "bindkey -M main '^I' autosuggest-accept\nbindkey -L -M main > $HOME/main.before\n"

def native_suggestion(s):
    """Grey history is deliberately different from the highest-ranked list item."""
    expected='record PRIORITY-most-recent-long'
    before='record PRIORITY'
    # The baseline runs the same rc with an empty plugin file.
    empty_plugin=ARTIFACTS/'disabled.zsh'
    empty_plugin.write_text('')
    baseline=Session(config('omz', NATIVE_HISTORY+NATIVE_TAB), cols=s.cols, plugin=empty_plugin)
    observations=[]
    try:
        for key in (b'\t', b'\x1b[C', b'\x1bOC'):
            clean(baseline,before)
            clean(s,before)
            assert listed(s)[0][1][3:]=='record PRIORITY-s'
            # Before the key, the editable row and grey suggestion match the baseline.
            assert s.screen.display[s.screen.cursor.y]==baseline.screen.display[baseline.screen.cursor.y]
            snapshot=s.snapshot('native-before-'+key.hex())
            assert s.screen.buffer[s.screen.cursor.y][4+len(before)].fg in ('brightblack','808080')
            baseline.send(key)
            s.send(key)
            actual=probe(s)
            original=probe(baseline)
            assert actual==original==expected,(key,actual,original)
            assert '\n' not in actual and '01 ' not in actual
            assert int((s.home/'state').read_text().split()[0])==len(expected)
            assert (s.home/'main.before').read_bytes()==(s.home/'main.after').read_bytes()
            assert not (s.home/'executed').exists()
            observations.append({'key':key.hex(),'baseline':original,'with_plugin':actual,
                                 'list_first':'record PRIORITY-s','grey':expected})
        return observations
    finally:
        baseline.close()

for cols in (80,100):
    run(f'native keys: grey Tab and CSI/SS3 right match baseline at {cols} columns',
        'omz',NATIVE_HISTORY+NATIVE_TAB,native_suggestion,cols=cols)

def native_completion_with_history(s):
    s.send('cat al')
    assert listed(s)[0][1][3:]=='cat alphabet-from-history'
    s.send(b'\t\t',.3)
    assert probe(s)=='cat alp'
    assert not listed(s)
    snapshot=s.snapshot('native-completion-with-history')
    visible='\n'.join(snapshot['lines'])
    assert 'alpha' in visible and 'alpine' in visible,visible
    assert not (s.home/'executed').exists()
run('native keys: Tab opens native completion even with matching history',
    'omz',NATIVE_HISTORY,native_completion_with_history)

def native_menu_arrows(s):
    s.send('cat native-file-')
    ready = (s.home/'ready').stat().st_mtime_ns
    s.send(b'\t\t\t', .4)
    first = s.screen.display[s.screen.cursor.y]
    assert 'native-file-' in first
    s.send(b'\x1b[B')
    second = s.screen.display[s.screen.cursor.y]
    assert second != first, (first, second)
    s.send(b'\x1b[A')
    assert s.screen.display[s.screen.cursor.y] == first
    s.send(b'\r')
    assert (s.home/'ready').stat().st_mtime_ns == ready, 'completion Enter executed the command'
    assert re.fullmatch(r'cat native-file-\d\d-long-name\s*', probe(s)), probe(s)
    assert not listed(s)
    clean(s, 'record MANUAL')
    assert probe(s) == 'record MANUAL' and listed(s)
run('native keys: completion menu arrows select files and Enter only accepts completion',
    'omz', 'touch native-file-{01..24}-long-name\n', native_menu_arrows)

def explicit_selection(s):
    query='record PRIORITY'
    grey=query+'-most-recent-long'
    for key in (b'\t',b'\x1b[C',b'\x1bOC'):
        clean(s,query)
        expected=listed(s)[1][1][3:]
        assert expected==query+'-medium' and expected!=grey
        s.send(b'\x1b[B')
        s.send(key)
        assert probe(s)==expected
        assert not listed(s) and not (s.home/'executed').exists()
    # Moving the input cursor cancels list ownership, even without changing BUFFER.
    clean(s,query)
    s.send(b'\x1b[B\x1b[D\x1b[C')
    assert probe(s)==query
    assert int((s.home/'state').read_text().split()[0])==len(query)
    s.send(b'\x1b[C')
    assert probe(s)==grey
    # Typing a new character and dismissing also return the keys to the input row.
    for sequence in (b'\x1b[B-',b'\x1b[B\x07'):
        clean(s,query)
        s.send(sequence)
        s.send(b'\t')
        assert probe(s)==grey
    clean(s,query)
    s.send(b'\x1b[BX\x7f\t')
    assert probe(s)==grey  # An edit followed by undoing it still relinquishes list selection.
    clean(s,query)
    s.send(b'\x1b1')
    assert probe(s)==query+'-s'
    assert not (s.home/'executed').exists()
run('native keys: explicit selection, cursor movement, edit, dismissal and Alt-1',
    'omz',NATIVE_HISTORY+NATIVE_TAB,explicit_selection)

CD_HISTORY = r'''
mkdir -p $HOME/completion/disk/{a,b,c,d,e,f,g,h,rk3588,zzzzzzzzzz}
for name in a b c d e f g h rk3588 zzzzzzzzzz; do print -s -- "cd disk/$name"; done
_hf_cd_changed() { print -r -- "$PWD" >> $HOME/directories; }
_hf_command_accepted() { print -r -- "$1" >> $HOME/accepted-commands; }
add-zsh-hook chpwd _hf_cd_changed
add-zsh-hook preexec _hf_command_accepted
_hf_original_enter() { print -r -- "$BUFFER" >> $HOME/accept-widget; zle .accept-line; }
zle -N _hf_original_enter
bindkey -M main '^M' _hf_original_enter
bindkey -M main '^J' _hf_original_enter
bindkey -L -M main > $HOME/main.before
'''

def cd_selected(s, enter=b'\r'):
    s.send('cd disk')
    rows=listed(s)
    assert len(rows)==10 and rows[8][1]=='09 cd disk/rk3588',rows
    s.send(b'\x1b[B'*8)
    assert probe(s)=='cd disk'  # Selection itself still does not change the input row.
    selected=s.snapshot('selected-item-09')
    assert selected['selected_rows']==[rows[8][0]],selected
    s.send(enter,.3)
    expected=str(s.home/'completion/disk/rk3588')
    actual=(s.home/'directories').read_text().splitlines()
    assert actual==[expected],actual
    assert (s.home/'accepted-commands').read_text()=='cd disk/rk3588\n'
    assert (s.home/'accept-widget').read_text()=='cd disk/rk3588\n'
    assert not listed(s) and probe(s)==''
    assert (s.home/'main.before').read_bytes()==(s.home/'main.after').read_bytes()
    s.snapshot('entered-selected-directory')
    return {'typed':'cd disk','selected':9,'executed':'cd disk/rk3588',
            'cwd':actual[0],'original_enter_calls':1,'enter_bytes':enter.hex()}

for cols in (80,100):
    run(f'Enter selection: cd disk item 09 executes rk3588 at {cols} columns',
        'omz',CD_HISTORY,cd_selected,cols=cols)
run('Enter selection: Ctrl-J preserves original accept widget',
    'omz',CD_HISTORY,lambda s:cd_selected(s,b'\n'))

def enter_without_selection(s):
    executed=''
    cases=(b'',b'\x1b[BX\x7f',b'\x1b[B\x1b[D\x1b[C',b'\x1b[B\x07')
    for sequence in cases:
        clean(s,'record MANUAL')
        s.send(sequence+b'\r')
        executed+='MANUAL\n'
        assert (s.home/'executed').read_text()==executed,(sequence,(s.home/'executed').read_text())
        assert not listed(s)
    return {'cases':['no selection','cancelled edit','cursor movement','Ctrl-G'],
            'executed':executed.splitlines()}
run('Enter selection: default and dismissed/edited choices execute only typed input',
    'omz','',enter_without_selection)


def mouse_report(button=0, x=4, y=11, release=False):
    return f'\x1b[<{button};{x};{y}' + ('m' if release else 'M')


def mouse_rows(s, query='record MANUAL'):
    clean(s, query)
    rows=listed(s)
    assert rows and 1000 << 5 in s.screen.mode and 1006 << 5 in s.screen.mode
    assert b'\x1b[?1049h' not in s.raw, 'must use the existing dropdown, no separate panel'
    if s.xterm:
        actual=[(y,line.rstrip()) for y,line in enumerate(s.xterm.state['lines']) if re.match(r'^\d\d ',line)]
        assert actual==rows,(actual,rows)
        assert s.xterm.state['mouse']=='vt200'
    return rows


def mouse_closed(s):
    assert 1000 << 5 not in s.screen.mode and 1006 << 5 not in s.screen.mode
    assert not s.screen.cursor.hidden
    if s.xterm:
        assert s.xterm.state['mouse']=='none'


def mouse_filled(s, command, entries=None):
    assert probe(s)==command and listed(s)
    assert 1000 << 5 in s.screen.mode and 1006 << 5 in s.screen.mode
    if s.xterm:
        assert s.xterm.state['mouse']=='vt200'
    if entries is not None:
        assert [text for _,text in listed(s)]==[text for _,text in entries], 'click changed candidates/order'
    assert int((s.home/'state').read_text().split()[0])==len(command)
    for name in ('executed','directories','accepted-commands','accept-widget'):
        assert not (s.home/name).exists(), 'click executed instead of filling: '+name


def mouse_cd(s):
    rows=mouse_rows(s, 'cd disk')
    y=rows[8][0]+1
    assert rows[8][1]=='09 cd disk/rk3588'
    before=s.snapshot('direct-click-before')
    caret=before['cursor']
    painted=s.mouse(y=y)
    press=s.snapshot('direct-click-press')
    assert press['selected_rows']==[y-1],press
    assert all(s.screen.buffer[y-1][x].bg==HOVER_BG for x in range(s.cols-1))
    assert press['lines']==before['lines'] and press['cursor']==caret, 'click moved text or input cursor'
    assert b'\x1b[2J' not in painted
    assert not (s.home/'accepted-commands').exists()
    s.mouse(y=y,release=True,delay=.3)
    mouse_filled(s, 'cd disk/rk3588', rows)
    s.snapshot('direct-click-filled-not-executed')
    # A queued extra click cannot execute the newly filled input.
    s.send(mouse_report(y=y)+mouse_report(y=y,release=True))
    mouse_filled(s, 'cd disk/rk3588', rows)
    # A mistaken first choice can be corrected using the original numbered menu.
    for idx in (2,9):
        current=listed(s)
        row=current[idx-1][0]+1
        s.mouse(y=row);s.mouse(y=row,release=True)
        mouse_filled(s, rows[idx-1][1][3:], rows)
        assert s.snapshot(f'reselected-{idx:02d}')['selected_rows']==[row-1]
        first_row=listed(s)[0][0]
        assert all(s.screen.buffer[first_row][x].fg=='green' for x in range(3,10))
    s.send(b'\r',.3)
    mouse_closed(s)
    assert (s.home/'directories').read_text()==str(s.home/'completion/disk/rk3588')+'\n'
    assert (s.home/'accepted-commands').read_text()=='cd disk/rk3588\n'
    assert (s.home/'accept-widget').read_text()=='cd disk/rk3588\n'
    assert probe(s)=='' and not listed(s)
    for keymap in ('main','viins','vicmd'):
        assert (s.home/f'{keymap}.before').read_bytes()==(s.home/f'{keymap}.after').read_bytes()
    s.send(mouse_report(y=y)+mouse_report(y=y,release=True))
    assert probe(s)==''
    assert (s.home/'accepted-commands').read_text()=='cd disk/rk3588\n'
    s.snapshot('direct-click-executed')
    return {'automatic_mouse':True,'item_09_screen_row':y,'executed':'cd disk/rk3588',
            'click_only_filled':True,'clicks':[9,2,9],'candidates_kept':True,
            'original_enter_calls_after_Enter':1,'terminal_replies':s.replies}

for mode, cols, prior in (('vi',80,0),('emacs',100,6),('omz',80,40),('omz',100,0)):
    extra=CD_HISTORY
    if prior: extra+=f'for n in {{1..{prior}}}; do print -r -- prior-output; done\n'
    run(f'mouse: click fills item 09, Enter executes, {mode}, {cols} columns, {prior} prior lines',mode,extra,mouse_cd,cols=cols)
run('mouse: click fills item 09 with multiline colored Chinese prompt','omz',CD_HISTORY+r'''
PROMPT=$'%F{blue}中文提示符：第一行%f\n%F{green}第二行%f > '
RPROMPT='%F{yellow}右侧%f'
''',mouse_cd,cols=80)


def mouse_cancel(s):
    for key in (b'\x07',b'\x03'):
        rows=mouse_rows(s)
        y=rows[8][0]+1
        s.mouse(y=y)
        s.send(key)
        mouse_closed(s)
        s.send(mouse_report(y=y,release=True))
        assert probe(s)==('' if key==b'\x03' else 'record MANUAL')
        assert not (s.home/'executed').exists()
    rows=mouse_rows(s)
    s.mouse(y=rows[8][0]+1)
    s.send(b'\x1b',.3)
    mouse_closed(s)
    s.send('i')
    assert probe(s)=='record MANUAL'
    assert listed(s)
    s.snapshot('direct-click-cancelled')
run('mouse: Ctrl-G/Ctrl-C/Esc release mouse and preserve vi editing','omz','',mouse_cancel)


def mouse_resize(s):
    for cols,rows in ((80,24),(40,12),(100,24)):
        entries=mouse_rows(s)
        y=entries[min(8,len(entries)-1)][0]+1
        s.mouse(y=y)
        s.resize(cols,rows)
        s.send(mouse_report(y=y,release=True))
        assert probe(s)=='record MANUAL'
        assert (s.home/'state').read_text().split()[-2:]==[str(cols),str(rows)]
        assert not (s.home/'executed').exists()
        assert len(s.snapshot(f'auto-resize-{cols}-{rows}')['selected_rows'])==1
    entries=listed(s)
    y=entries[2][0]+1
    expected=entries[2][1][3:].removeprefix('record ')
    s.mouse(y=y);s.mouse(y=y,release=True)
    mouse_filled(s, 'record '+expected, entries)
    s.send(b'\r')
    assert (s.home/'executed').read_text()==expected+'\n'
    mouse_closed(s)
run('mouse: resizing cancels stale click and new coordinates still fill','omz','',mouse_resize)


def mouse_invalid(s):
    rows=mouse_rows(s)
    y=rows[8][0]+1
    cases=[mouse_report(y=y,release=True),
           mouse_report(y=y)+mouse_report(y=y-1,release=True)+mouse_report(y=y,release=True),
           mouse_report(y=rows[0][0])+mouse_report(y=rows[0][0],release=True),
           mouse_report(y=24)+mouse_report(y=24,release=True),
           mouse_report(x=0,y=y)+mouse_report(x=0,y=y,release=True)]
    for button in (1,2,4,8,16,32,64,65):
        cases.append(mouse_report(button,y=y)+mouse_report(button,y=y,release=True))
    cases += [f'\x1b[<999999999999999999999;4;{y}M'+mouse_report(y=y,release=True),
              '\x1b[<0;4;garbageM'+mouse_report(y=y,release=True)]
    for data in cases:
        s.send(data,.15)
        assert not (s.home/'executed').exists(),repr(data)
        assert probe(s)=='record MANUAL',repr(data)
    s.send('\x1b[<0;',.1);s.send(f'4;{y}M',.2)
    s.send('\x1b[<0;4;',.1);s.send(f'{y}m',.3)
    mouse_filled(s, 'record MANUAL-07', rows)
    s.send(b'\r')
    assert (s.home/'executed').read_text()=='MANUAL-07\n'
    mouse_closed(s)
    return {'ignored_inputs':len(cases),'fragmented_click_fills_only':True,'Enter_executes_once':True}
run('mouse: invalid/outside/modified/non-left events never execute or insert reports','omz','',mouse_invalid)


def mouse_edit(s):
    for edit in (b'X\x7f',b'\x1b[B',b'\x1b[D\x1b[C'):
        rows=mouse_rows(s)
        y=rows[8][0]+1
        s.mouse(y=y)
        s.send(edit+mouse_report(y=y,release=True).encode())
        assert not (s.home/'executed').exists()
        assert probe(s)=='record MANUAL'
    rows=mouse_rows(s)
    y=rows[8][0]+1
    s.mouse(y=y)
    payload=mouse_report(y=y)+mouse_report(y=y,release=True)
    s.send('\x1b[200~'+payload+'\x1b[201~',.3)
    assert not (s.home/'executed').exists()
    s.send(b'\x03')
    mouse_closed(s)
run('mouse: edit/cursor/arrow and bracketed paste cancel held click','omz','',mouse_edit)


def mouse_native(s):
    query='record PRIORITY'
    for key in (b'\t',b'\x1b[C',b'\x1bOC'):
        mouse_rows(s,query)
        queries=s.raw.count(b'\x1b[?6n')
        s.send(key)
        assert probe(s)==query+'-most-recent-long'
        assert s.raw.count(b'\x1b[?6n')==queries, 'typing queried cursor position'
        rows=mouse_rows(s,query)
        y=rows[1][0]+1
        s.mouse(y=y)
        s.send(key)
        assert probe(s)==query+'-most-recent-long'
        s.send(mouse_report(y=y,release=True))
        assert not (s.home/'executed').exists()
run('mouse: automatic capture leaves gray Tab and right untouched','omz',NATIVE_HISTORY+NATIVE_TAB,mouse_native)


def mouse_completion(s):
    mouse_rows(s,'cat al')
    s.send(b'\t\t',.3)
    mouse_closed(s)
    assert probe(s)=='cat alp'
    visible='\n'.join(s.screen.display)
    assert 'alpha' in visible and 'alpine' in visible
    s.snapshot('auto-mouse-native-completion')
run('mouse: native completion releases capture automatically','omz',NATIVE_HISTORY,mouse_completion)


def mouse_empty(s):
    s.send('nonexistent-history-command')
    mouse_closed(s)
    assert probe(s)=='nonexistent-history-command'
    assert b'\x1b[?1000h' not in s.raw and b'\x1b[?6n' not in s.raw
run('mouse: empty history never captures mouse or queries position','vi','fc -p $HOME/empty 0\n',mouse_empty)


def mouse_unicode(s):
    rows=mouse_rows(s,'record 中文')
    assert len(rows)==1 and rows[0][1].endswith('…')
    y=rows[0][0]+1
    s.mouse(x=40,y=y);s.mouse(x=40,y=y,release=True)
    mouse_filled(s, 'record 中文'+'宽'*100, rows)
    s.send(b'\r')
    assert (s.home/'executed').read_text()=='中文'+'宽'*100+'\n'
    mouse_closed(s)
run('mouse: clipped Unicode row fills full command, then Enter executes','omz',"print -s -- 'record 中文"+'宽'*100+"'\n",mouse_unicode,cols=80)


def mouse_wrapped(s):
    query='record '+'wide'*28
    clean(s,query)
    assert probe(s)==query
    rows=listed(s)
    y=rows[2][0]+1
    s.send(b'\x1b[D'*60,.1)
    assert probe(s)==query
    before=s.snapshot('wrapped-middle-before')
    s.mouse(y=y)
    after=s.snapshot('wrapped-middle-press')
    assert before['lines']==after['lines'] and before['cursor']==after['cursor']
    s.mouse(y=y,release=True)
    mouse_filled(s, query+'-08', rows)
    s.send(b'\r')
    assert (s.home/'executed').read_text()=='wide'*28+'-08\n'
    mouse_closed(s)
run('mouse: wrapped input, wrapped gray suffix and cursor in middle','omz',
    "for n in {01..10}; do print -s -- 'record "+'wide'*28+"-'$n; done\n",mouse_wrapped,cols=80)


def mouse_no_response(s):
    rows=mouse_rows(s)
    y=rows[8][0]+1
    start=time.monotonic()
    s.mouse(y=y,delay=.6)
    assert time.monotonic()-start<1
    s.mouse(y=y,release=True)
    assert not (s.home/'executed').exists()
    assert probe(s)=='record MANUAL'
    s.send('\x1b[?2;1R')  # A late private report is consumed, never inserted.
    assert probe(s)=='record MANUAL'
    # Keyboard input while waiting is replayed in order.
    s.mouse(y=y,delay=.02)
    s.send('X\x7f',.6)
    assert probe(s)=='record MANUAL'
    s.mouse(y=y,delay=.02)
    s.send(b'\x1b',.6)
    mouse_closed(s)
    s.send('\x1b[?2;1R'+mouse_report(y=y,release=True))
    s.send('i')
    assert probe(s)=='record MANUAL'
    s.send(b'\x07')
    mouse_closed(s)
    s.send(b'\r')
    assert (s.home/'executed').read_text()=='MANUAL\n'
run('mouse: no terminal position reply never guesses, leaks text or swallows keys','omz','',mouse_no_response,cpr=False)



def mouse_function_key(s):
    mouse_rows(s)
    s.send(b'\x1b[1;2R')
    assert (s.home/'function-key').read_text()=='called\n'
    assert probe(s)=='record MANUAL'
    assert not s.replies
run('mouse: private cursor replies do not override Shift-F3', 'omz', r'''
_hf_function_key() { print -r -- called > $HOME/function-key; }
zle -N _hf_function_key
bindkey -M main '\e[1;2R' _hf_function_key
''',mouse_function_key)


def mouse_fill_then_edit(s):
    entries=mouse_rows(s)
    y=entries[8][0]+1
    command=entries[8][1][3:]
    s.mouse(y=y);s.mouse(y=y,release=True)
    mouse_filled(s,command,entries)
    s.send('-EDITED')
    assert probe(s)==command+'-EDITED' and not (s.home/'executed').exists()
    assert not listed(s), 'typing must leave the preserved menu and run a new search'
    s.send(b'\r')
    assert (s.home/'executed').read_text()==command.removeprefix('record ')+'-EDITED\n'
run('mouse: filled command remains editable and Enter executes edited input','omz','',mouse_fill_then_edit)


def mouse_fill_then_cancel(s):
    entries=mouse_rows(s)
    y=entries[8][0]+1
    s.mouse(y=y);s.mouse(y=y,release=True)
    mouse_filled(s,entries[8][1][3:],entries)
    s.send(b'\x03')
    assert probe(s)=='' and not (s.home/'executed').exists()
    mouse_closed(s)
run('mouse: Ctrl-C cancels filled command without executing','omz','',mouse_fill_then_cancel)


def mouse_reselect_then_enter(s):
    entries=mouse_rows(s)
    for idx in (9,2):
        y=listed(s)[idx-1][0]+1
        s.mouse(y=y);s.mouse(y=y,release=True)
        mouse_filled(s,entries[idx-1][1][3:],entries)
    s.send(b'\r')
    assert (s.home/'executed').read_text()==entries[1][1][3:].removeprefix('record ')+'\n'
    mouse_closed(s)
    assert probe(s)=='' and not listed(s)
run('mouse: second choice replaces first, Enter executes only second choice','omz','',mouse_reselect_then_enter)


def mouse_preserved_dismiss(s):
    entries=mouse_rows(s)
    y=entries[8][0]+1
    s.mouse(y=y);s.mouse(y=y,release=True)
    command=entries[8][1][3:]
    mouse_filled(s,command,entries)
    s.send(b'\x07')
    mouse_closed(s)
    assert probe(s)==command and not listed(s)
    s.send(mouse_report(y=y)+mouse_report(y=y,release=True))
    assert probe(s)==command and not (s.home/'executed').exists()
    s.send(b'\r')
    assert (s.home/'executed').read_text()==command.removeprefix('record ')+'\n'
run('mouse: Ctrl-G explicitly closes preserved list and keeps filled command','omz','',mouse_preserved_dismiss)


def mouse_preserved_keyboard(s):
    entries=mouse_rows(s)
    y=entries[8][0]+1
    s.mouse(y=y);s.mouse(y=y,release=True)
    mouse_filled(s,entries[8][1][3:],entries)
    s.send(b'\x1b[A\r')
    assert (s.home/'executed').read_text()==entries[7][1][3:].removeprefix('record ')+'\n'
    mouse_closed(s)
run('mouse: preserved menu still supports arrow selection and Enter','omz','',mouse_preserved_keyboard)

RECENT_COMMANDS = [f'record RECENT-{n:02d}' for n in range(1, 15)] + ['record RECENT-most-recent-long-15']
RECENT_HISTORY = 'fc -p $HOME/recent-history 100\n' + ''.join(
    'print -s -- ' + shlex.quote(cmd) + '\n' for cmd in RECENT_COMMANDS)

def recent_rows(s, expected=None):
    expected = expected or list(reversed(RECENT_COMMANDS))[:10]
    rows = listed(s)
    assert [line[3:] for _, line in rows] == expected, rows
    # No fuzzy query exists: neither selected nor unselected rows inherit green hits.
    for y, line in rows:
        for x in range(len(line)):
            cell = s.screen.buffer[y][x]
            assert cell.fg == (HOVER_FG if cell.bg == HOVER_BG else 'default'), cell
    return rows

def recent_selected(s, index, expected=None):
    rows = recent_rows(s, expected)
    assert s.snapshot(f'recent-selected-{index}')['selected_rows'] == [rows[index-1][0]]
    assert all(s.screen.buffer[rows[index-1][0]][x].bg == HOVER_BG for x in range(s.cols-1))

def recent_menu(s):
    assert probe(s) == '' and not listed(s)
    mouse_closed(s)
    for opening in (b'\x1b[A', b'\x1b[B', b'\x1bOA', b'\x1bOB'):
        clean(s, '')
        s.send(opening)
        assert probe(s) == ''
        recent_selected(s, 1)
        before = list(s.screen.display)
        cursor = (s.screen.cursor.y, s.screen.cursor.x)
        for key, index in ((b'\x1b[B', 2), (b'\x1bOA', 1), (b'\x1b[A', 10), (b'\x1bOB', 1)):
            raw = s.send(key)
            recent_selected(s, index)
            assert s.screen.display == before
            assert (s.screen.cursor.y, s.screen.cursor.x) == cursor
            assert b'\n' not in raw and b'\x1b[2J' not in raw
            assert probe(s) == ''
        s.send(b'\x07')
        assert probe(s) == '' and not listed(s)
        mouse_closed(s)
    s.send(b'\x1b[B\x1b[B\r')
    assert (s.home/'executed').read_text() == 'RECENT-14\n'
    assert probe(s) == '' and not listed(s)
    s.send(b'\r')
    assert (s.home/'executed').read_text() == 'RECENT-14\n'
    for keymap in ('main', 'viins', 'vicmd'):
        assert (s.home/(keymap+'.before')).read_bytes() == (s.home/(keymap+'.after')).read_bytes()
    return {'order': 'newest first', 'first_arrow_selects': 1, 'typing_required': False}

for mode in ('vi', 'emacs', 'omz'):
    for cols in (80, 100):
        run(f'history keys: empty arrows show recent history, {mode}, {cols} columns',
            mode, RECENT_HISTORY, recent_menu, cols=cols)

def recent_transitions(s):
    s.send(b'\x1b[A')
    recent_selected(s, 1)
    s.send('record RECENT')
    assert probe(s) == 'record RECENT'
    assert listed(s)[0][1][3:] == 'record RECENT-14', listed(s)
    assert s.screen.buffer[listed(s)[1][0]][3].fg == 'green'
    s.send(b'\x15')
    assert probe(s) == '' and not listed(s)
    s.send(b'\x1b[B')
    recent_selected(s, 1)
    s.send(b'X\x7f')
    assert probe(s) == '' and not listed(s)
    s.send(b'\x1b[A\t')
    assert probe(s) == RECENT_COMMANDS[-1] and not listed(s)
    assert not (s.home/'executed').exists()
    clean(s, 'zzzzNoMatch')
    for key in (b'\x1b[A', b'\x1b[B', b'\x1bOA', b'\x1bOB'):
        s.send(key)
        assert probe(s) == 'zzzzNoMatch' and not listed(s)
    clean(s, '')
    s.send(b'\x1b[A\x07\x1b[B')
    assert probe(s) == ''
    recent_selected(s, 1)
    s.send(b'\x03')
    assert probe(s) == '' and not listed(s)
    mouse_closed(s)
    s.send(b'\x1b[A')
    recent_selected(s, 1)
    s.send(b'\x1b', .3)
    assert probe(s) == '' and not listed(s)
    mouse_closed(s)
    s.send('i')
    assert probe(s) == '' and not listed(s)
    s.send(b'\x1b[B')
    recent_selected(s, 1)
run('history keys: edit changes recent menu to fuzzy search; empty/no match never recalls native history',
    'omz', RECENT_HISTORY, recent_transitions)

def history_pages(s, mode):
    empty_plugin = ARTIFACTS/'history-disabled.zsh'
    empty_plugin.write_text('')
    baseline = Session(config(mode, RECENT_HISTORY + "bindkey -M main '\\e[A' up-history\nbindkey -M main '\\e[B' down-history\n"),
                       cols=s.cols, plugin=empty_plugin)
    observations = []
    try:
        for query in ('', 'record RECENT'):
            clean(s, query)
            clean(baseline, query)
            if query:
                s.send(b'\x1b[B')  # A fuzzy selection must not steal PageUp.
            for page, original in ((b'\x1b[5~', b'\x1b[A'),)*3 + ((b'\x1b[6~', b'\x1b[B'),)*3:
                s.send(page)
                baseline.send(original)
                actual, expected = probe(s), probe(baseline)
                assert actual == expected, (page, actual, expected)
                assert not listed(s), 'PageUp/PageDown unexpectedly reopened fuzzy results'
                mouse_closed(s)
                observations.append(actual)
            assert probe(s) == query
        assert not (s.home/'executed').exists()
        return observations
    finally:
        baseline.close()
for mode in ('vi', 'emacs', 'omz'):
    run(f'history keys: PageUp/PageDown match native history navigation, {mode}',
        mode, RECENT_HISTORY, lambda s, mode=mode: history_pages(s, mode))

def recent_mouse(s):
    s.send(b'\x1b[A')
    entries = recent_rows(s)
    for idx in (9, 2):
        y = listed(s)[idx-1][0] + 1
        s.mouse(y=y); s.mouse(y=y, release=True)
        mouse_filled(s, entries[idx-1][1][3:], entries)
        recent_selected(s, idx)
    s.send(b'\r')
    assert (s.home/'executed').read_text() == 'RECENT-14\n'
    assert probe(s) == '' and not listed(s)
    mouse_closed(s)
run('history keys: mouse can choose twice from preserved recent history; Enter executes last choice',
    'omz', RECENT_HISTORY, recent_mouse)

def recent_pages_after_mouse(s):
    s.send(b'\x1b[A')
    entries = recent_rows(s)
    y = entries[8][0] + 1
    s.mouse(y=y); s.mouse(y=y, release=True)
    mouse_filled(s, entries[8][1][3:], entries)
    s.send(b'\x1b[5~')
    assert probe(s) == RECENT_COMMANDS[-1] and not listed(s)
    s.send(b'\x1b[6~')
    assert probe(s) == entries[8][1][3:] and not listed(s)
    mouse_closed(s)
    assert not (s.home/'executed').exists()
run('history keys: PageUp/PageDown close pinned mouse menu and restore the input',
    'omz', RECENT_HISTORY, recent_pages_after_mouse)

def recent_empty(s):
    for key in (b'\x1b[A', b'\x1b[B', b'\x1bOA', b'\x1bOB', b'\x1b[5~', b'\x1b[6~'):
        s.send(key)
        assert probe(s) == '' and not listed(s)
        mouse_closed(s)
run('history keys: empty history leaves empty input and no menu',
    'omz', 'fc -p $HOME/no-history 100\n', recent_empty)

def recent_disabled(s):
    for key in (b'\x1b[A', b'\x1b[B'):
        s.send(key)
        assert probe(s) == '' and not listed(s)
        mouse_closed(s)
    s.send(b'\x1b[5~')
    assert probe(s) == RECENT_COMMANDS[-1] and not listed(s)
run('history keys: max_show zero disables menu but keeps PageUp history available',
    'omz', RECENT_HISTORY + 'HIST_FUZZY_MAX_SHOW=0\n', recent_disabled)

def recent_filtered(s):
    s.send(b'\x1b[A')
    recent_selected(s, 1, list(reversed(RECENT_COMMANDS)))
    assert len(listed(s)) == 15
run('history keys: recent order deduplicates, filters ignored commands and respects max 15',
    'omz', RECENT_HISTORY + "HIST_FUZZY_MAX_SHOW=15\nprint -s -- 'record RECENT-most-recent-long-15'\nprint -s -- 'shl'\n", recent_filtered)

report = {
    'plugin': PLUGIN,
    'selection_palette': {'background': HOVER_BG, 'text': HOVER_FG, 'match': HOVER_MATCH,
                          'text_contrast': contrast(HOVER_FG, HOVER_BG),
                          'match_contrast': contrast(HOVER_MATCH, HOVER_BG)},
    'terminal': str(args.xterm_headless) if args.xterm_headless else 'pyte with CPR replies',
    'sha256': hashlib.sha256(Path(PLUGIN).read_bytes()).hexdigest(),
    'matrix': matrix,
    'edges': edge_results,
}
(ARTIFACTS / 'results.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
passed = all(r['pass'] for r in matrix) and all(r['passed'] for r in edge_results)
print(f"{'PASS' if passed else 'FAIL'}: {len(matrix)} configurations, {len(edge_results)} edge cases; {ARTIFACTS / 'results.json'}")
if not passed:
    for r in matrix + edge_results:
        if 'error' in r:
            print(r['error'])
sys.exit(not passed)
