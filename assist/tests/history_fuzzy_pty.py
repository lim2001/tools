#!/usr/bin/env python3
"""PTY acceptance for history_fuzzy (requires Python 3, pyte, zsh and oh-my-zsh).

Run: python3 assist/tests/history_fuzzy_pty.py
Optional: --omz /path/to/oh-my-zsh --plugin /path/to/history_fuzzy.zsh
Each child uses an empty environment, a fresh HOME and a private plugin copy.
Only synthetic history is loaded. The PTY and pyte share dimensions and never
reply to DSR. Raw terminal bytes, screen snapshots and results are kept in /tmp.
"""
import argparse
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

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--plugin', type=Path, default=Path(__file__).resolve().parents[1] / 'history_fuzzy.zsh')
parser.add_argument('--omz', type=Path, default=Path.home() / '.oh-my-zsh')
parser.add_argument('--focused', action='store_true', help='only native key and Enter selection regressions')
args = parser.parse_args()
PLUGIN = str(args.plugin.resolve())
OMZ = str(args.omz.resolve())
if not Path(OMZ, 'oh-my-zsh.sh').is_file():
    parser.error('--omz must point to oh-my-zsh with vi-mode, autosuggestions and syntax-highlighting')
ARTIFACTS = Path(tempfile.mkdtemp(prefix='history-fuzzy-pty-'))
print('Evidence: ' + str(ARTIFACTS), flush=True)

class Session:
    def __init__(self, rc, cols=100, rows=24, plugin=None):
        self.home = Path(tempfile.mkdtemp(prefix="case-", dir=ARTIFACTS))
        (self.home / ".zshrc").write_text(rc)
        if plugin:
            shutil.copyfile(plugin, self.home / 'history_fuzzy.zsh')
        self.cols, self.rows = cols, rows
        self.screen = pyte.Screen(cols, rows)
        self.stream = pyte.ByteStream(self.screen)
        self.raw = bytearray()
        pid, fd = pty.fork()
        if pid == 0:
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
            env = {"HOME": str(self.home), "ZDOTDIR": str(self.home),
                   "PATH": "/usr/local/bin:/usr/bin:/bin", "TERM": "xterm-256color",
                   "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "SHELL": "/usr/bin/zsh"}
            os.execve("/usr/bin/zsh", ["zsh", "-d", "-i"], env)
        self.pid, self.fd = pid, fd
        self.read(1)

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
                self.stream.feed(data)  # No DSR replies are ever sent.
        return bytes(self.raw[start:])

    def send(self, data, delay=.2):
        os.write(self.fd, data.encode() if isinstance(data, str) else data)
        return self.read(delay)

    def snapshot(self, label):
        result = {"label": label, "cursor": [self.screen.cursor.y, self.screen.cursor.x],
                  "lines": self.screen.display,
                  "cyan_rows": [y for y in range(self.rows)
                                if any(self.screen.buffer[y][x].bg == "cyan" for x in range(self.cols))]}
        (self.home / (label + ".json")).write_text(json.dumps(result, ensure_ascii=False, indent=2))
        return result

    def resize(self, cols, rows):
        self.cols, self.rows = cols, rows
        self.screen.resize(rows, cols)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        os.kill(self.pid, signal.SIGWINCH)
        self.read(.3)

    def close(self):
        (self.home / "terminal.raw").write_bytes(self.raw)
        os.kill(self.pid, signal.SIGTERM)
        os.close(self.fd)
        os.waitpid(self.pid, 0)



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
            s.read(.02)
            return target.read_text().removesuffix('\n')
        s.read(.005)
    raise AssertionError('probe timed out')


def listed(s):
    return [(y, line.rstrip()) for y, line in enumerate(s.screen.display) if re.match(r'^\d\d ', line)]


def clean(s, data):
    s.send(b'\x03', .08)
    s.send(data, .15)


def check_hover(s, idx):
    rows = listed(s)
    assert len(rows) == 10, rows
    cyan = [y for y in range(s.rows) if any(c.bg == 'cyan' for c in s.screen.buffer[y].values())]
    assert cyan == [rows[idx-1][0]], (idx, cyan, rows)
    y = cyan[0]
    assert all(s.screen.buffer[y][x].bg == 'cyan' for x in range(s.cols-1)), 'hover not full width'


def exercise(mode, cols):
    s = Session(config(mode), cols=cols, plugin=PLUGIN)
    checks = []
    try:
        assert not re.search(rb'(command not found|read-only|bad pattern|parse error|maximum nested)', s.raw), bytes(s.raw)
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
        checks.append('CSI first arrow; down down up up; cyan full row; stable cursor/text; no scrolling')
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
        assert not listed(s) and not s.snapshot('entered')['cyan_rows']
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
        checks.append('Ctrl-G closes until next edit; normal input resumes')
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
        assert b'\x1b[6n' not in s.raw
        assert not re.search(rb'(command not found|read-only|bad pattern|parse error|maximum nested)', s.raw)
        checks.append('no DSR, errors, or stray list text in BUFFER')
        return {'mode': mode, 'size': [cols,24], 'pass': True, 'checks': checks, 'artifacts': str(s.home)}
    except Exception as e:
        s.snapshot('FAILED')
        return {'mode': mode, 'size': [cols,24], 'pass': False, 'error': traceback.format_exc(), 'checks': checks, 'artifacts': str(s.home)}
    finally:
        s.close()



matrix=[]
for mode in (() if args.focused else ('vi','emacs','omz')):
    for cols in (80,100):
        result=exercise(mode,cols)
        matrix.append(result)
        print(('PASS' if result['pass'] else 'FAIL') + f' {mode} {cols}x24', flush=True)

edge_results=[]
def run(name, mode, extra, test, cols=100, rows=24):
    if args.focused and not name.startswith(('native keys:', 'Enter selection:')):
        return
    s=Session(config(mode,extra), cols=cols, rows=rows, plugin=PLUGIN)
    try:
        detail=test(s)
        assert not re.search(rb'(command not found|read-only|bad pattern|parse error|maximum nested)', s.raw)
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
    s.send(b'\x1b[A');assert s.snapshot('wrap-up')['cyan_rows']==[listed(s)[-1][0]]
run('15 results and navigation wrap','omz','HIST_FUZZY_MAX_SHOW=15\n',fifteen)

def resize(s):
    s.send('record MANUAL');assert len(listed(s))==10
    for cols,rows in ((80,24),(40,12),(25,8),(100,24)):
        s.resize(cols,rows)
        s.send(b'\x1b[B')
        b=probe(s)
        assert b=='record MANUAL',b
        assert 0 < len(listed(s)) <= min(10,rows-4), listed(s)
        cyan=s.snapshot(f'resize-{cols}x{rows}')['cyan_rows']
        assert len(cyan)==1,cyan
        assert all(s.screen.buffer[cyan[0]][x].bg=='cyan' for x in range(cols-1))
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
    assert selected['cyan_rows']==[rows[8][0]],selected
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


report = {
    'plugin': PLUGIN,
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
