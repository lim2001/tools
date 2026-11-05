#!/usr/bin/env python3
"""Isolated installer and real PTY startup checks; never read personal rc/history."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import struct
import subprocess
import tempfile
import termios
import time

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--package',type=Path,default=Path(__file__).resolve().parents[1])
args=parser.parse_args()
PACKAGE=args.package.resolve()
ARTIFACTS=Path(tempfile.mkdtemp(prefix='easyCmd-install-test-'))
BASH=shutil.which('bash')
ZSH=shutil.which('zsh')
assert BASH and ZSH
results=[]

def home(name):
    p=ARTIFACTS/name
    p.mkdir()
    return p

def env(p,**extra):
    return dict(HOME=str(p),ZDOTDIR=str(p),PATH='/usr/local/bin:/usr/bin:/bin',TERM='xterm-256color',LC_ALL='C.UTF-8',**extra)

def install(p,package=PACKAGE,environ=None,success=True):
    r=subprocess.run([BASH,str(package/'install_easyCmd.sh'),'--no-shell'],env=environ or env(p),text=True,capture_output=True)
    (p/'install-output.txt').write_text(r.stdout+r.stderr)
    assert (r.returncode==0)==success,(r.returncode,r.stdout,r.stderr)
    return r

def check(name,test):
    p=home(name)
    test(p)
    results.append(dict(name=name,passed=True,artifacts=str(p)))
    print('PASS '+name,flush=True)

def basic(p):
    rc=p/'.zshrc'
    # Installation must not execute arbitrary commands from an existing rc.
    original=b'export EXAMPLE="keep these spaces"\ntouch "$HOME/rc-was-executed"\n'
    rc.write_bytes(original);rc.chmod(0o640)
    install(p)
    assert not (p/'rc-was-executed').exists()
    backups=list(p.glob('.zshrc.easyCmd.bak.*'))
    assert len(backups)==1 and backups[0].read_bytes()==original
    assert rc.read_bytes().startswith(original)
    assert rc.stat().st_mode&0o777==0o640
    installed=p/'.local/share/easyCmd'
    for name in ('easyCmd.zsh','load_easyCmd.zsh','install_easyCmd.sh'):
        assert (installed/name).read_bytes()==(PACKAGE/name).read_bytes()
    before=rc.read_bytes();install(p)
    assert rc.read_bytes()==before
    assert len(list(p.glob('.zshrc.easyCmd.bak.*')))==1
    assert rc.read_text().count('# >>> easyCmd >>>')==1
check('backup-idempotence-and-no-config-execution',basic)

def legacy(p):
    rc=p/'.zshrc'
    prefix='HIST_FUZZY_MAX_SHOW=5\nHIST_FUZZY_IGNORE=(shl shh legacy-hidden)\n'
    rc.write_text(prefix+'[ -f ~/tools/assist/history_fuzzy.zsh ] && source ~/tools/assist/history_fuzzy.zsh\nsource "$HOME/tools/assist/rc_hf.zsh"\n')
    install(p)
    text=rc.read_text()
    assert text.startswith(prefix)
    assert 'history_fuzzy.zsh' not in text and 'rc_hf.zsh' not in text
    assert text.count('# >>> easyCmd >>>')==1
    assert not (p/'rc-was-executed').exists()
check('legacy-source-lines-migrated',legacy)

def spaces(p):
    package=p/'copy with spaces $(touch UNEXPECTED)'
    package.mkdir()
    for name in ('easyCmd.zsh','load_easyCmd.zsh','install_easyCmd.sh'):
        shutil.copy2(PACKAGE/name,package/name)
    install(p,package)
    assert not (p/'UNEXPECTED').exists()
    assert (p/'.local/share/easyCmd/easyCmd.zsh').is_file()
check('portable-package-path-with-spaces-and-metacharacters',spaces)

def symlink(p):
    config=p/'config space';config.mkdir()
    target=p/'managed rc';target.write_text('# preserve link\n')
    (config/'.zshrc').symlink_to(target)
    e=env(p);e['ZDOTDIR']=str(config)
    install(p,environ=e)
    assert (config/'.zshrc').is_symlink()
    assert '# >>> easyCmd >>>' in target.read_text()
    assert len(list(p.glob('managed rc.easyCmd.bak.*')))==1
check('ZDOTDIR-and-symlink-preserved',symlink)

def invalid(p):
    rc=p/'.zshrc';text='if true; then\n'
    rc.write_text(text)
    install(p,success=False)
    assert rc.read_text()==text
    assert not list(p.glob('.zshrc.easyCmd.bak.*'))
    assert not (p/'.local/share/easyCmd').exists()
check('invalid-rc-left-untouched',invalid)

def invalid_block(p):
    rc=p/'.zshrc';text='# >>> easyCmd >>>\ncustom text\n'
    rc.write_text(text);install(p,success=False)
    assert rc.read_text()==text and not (p/'.local/share/easyCmd').exists()
check('incomplete-managed-block-left-untouched',invalid_block)

def missing(p):
    e=env(p);e['PATH']=str(p/'no-programs')
    install(p,environ=e,success=False)
    assert not (p/'.zshrc').exists() and not (p/'.local').exists()
check('missing-zsh-reported-without-changes',missing)

def gui(p):
    stub=p/'bin';stub.mkdir()
    terminal=stub/'x-terminal-emulator'
    terminal.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$HOME/terminal-args"\nshift\nexec "$@"\n')
    terminal.chmod(0o755)
    e=env(p);e['PATH']=str(stub)+':'+e['PATH'];e['DISPLAY']=':test'
    r=subprocess.run([BASH,str(PACKAGE/'install_easyCmd.sh')],env=e,text=True,capture_output=True)
    assert r.returncode==0,(r.stdout,r.stderr)
    assert (p/'terminal-args').read_text().splitlines()==['-e','bash',str(PACKAGE/'install_easyCmd.sh')]
    assert (p/'.local/share/easyCmd/easyCmd.zsh').is_file()
check('desktop-execution-opens-a-terminal',gui)

RC=r'''
HISTFILE=$HOME/synthetic-history
HISTSIZE=100
SAVEHIST=0
PROMPT='ec> '
RPROMPT=''
KEYTIMEOUT=10
bindkey -e
record() { print -r -- "$*" >> $HOME/executed; }
for n in {01..35}; do print -s -- "record DEMO-$n"; done
_probe() {
 print -r -- "$BUFFER" > $HOME/input
 print -rl -- "$CURSOR" "$_EASYCMD_VERSION" "$EASYCMD_MAX_SHOW" "${#_easyCmd_shown}" "${EASYCMD_IGNORE[*]}" > $HOME/state
}
zle -N _probe
bindkey '^X?' _probe
autoload -Uz add-zle-hook-widget
_ready() { : > $HOME/ready; }
add-zle-hook-widget line-init _ready
'''

def pty_start(p,interactive_install=False,legacy_options=False):
    rc=RC
    if legacy_options:rc+='\nHIST_FUZZY_MAX_SHOW=5\nHIST_FUZZY_IGNORE=(shl shh legacy-hidden)\n'
    (p/'.zshrc').write_text(rc)
    if not interactive_install:install(p)
    pid,fd=pty.fork()
    if pid==0:
        fcntl.ioctl(0,termios.TIOCSWINSZ,struct.pack('HHHH',24,100,0,0))
        argv=[BASH,str(PACKAGE/'install_easyCmd.sh')] if interactive_install else [ZSH,'-di']
        os.execve(argv[0],argv,env(p))
    raw=bytearray()
    def read(duration=.15):
        deadline=time.monotonic()+duration
        while time.monotonic()<deadline:
            if select.select([fd],[],[],max(0,deadline-time.monotonic()))[0]:
                try:data=os.read(fd,65536)
                except OSError:break
                if not data:break
                raw.extend(data)
    def send(data):os.write(fd,data.encode() if isinstance(data,str) else data);read()
    def probe():
        before=(p/'input').stat().st_mtime_ns if (p/'input').exists() else 0
        send(b'\x18?')
        deadline=time.monotonic()+3
        while not (p/'input').exists() or (p/'input').stat().st_mtime_ns==before:
            assert time.monotonic()<deadline,'probe timed out'
            read(.02)
        return (p/'input').read_text().removesuffix('\n'),(p/'state').read_text().splitlines()
    try:
        deadline=time.monotonic()+10
        while not (p/'ready').exists():
            assert time.monotonic()<deadline,bytes(raw)[-2000:]
            read(.05)
        read(.1)
        assert probe()[1][1]=='28'
        send('record DEMO');send(b'\x1b[B'*10)
        typed,state=probe()
        assert typed=='record DEMO' and state[0]=='11', (typed,state)
        assert state[3]==('5' if legacy_options else '20'),state
        if legacy_options:assert state[4]=='shl shh legacy-hidden',state
        send('-EDITED\r')
        assert (p/'executed').read_text()=='DEMO-EDITED\n'
        send('record DEMO');send(b'\x1b[B\t')
        typed,state=probe()
        assert typed.startswith('record DEMO-') and state[3]=='0'
        assert (p/'executed').read_text()=='DEMO-EDITED\n'
        assert b'command not found' not in raw and b'parse error' not in raw
    finally:
        (p/'terminal.raw').write_bytes(raw)
        os.kill(pid,signal.SIGTERM);os.close(fd);os.waitpid(pid,0)
check('fresh-zsh-without-Oh-My-Zsh-PTY',pty_start)
check('installer-enters-working-zsh-automatically-PTY',lambda p:pty_start(p,interactive_install=True))
check('cold-start-migrates-legacy-options-PTY',lambda p:pty_start(p,legacy_options=True))
report={'passed':True,'package':str(PACKAGE),'sha256':hashlib.sha256((PACKAGE/'easyCmd.zsh').read_bytes()).hexdigest(),'cases':results}
(ARTIFACTS/'results.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print('PASS: '+str(len(results))+' cases; '+str(ARTIFACTS/'results.json'))
