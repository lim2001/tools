#!/usr/bin/env bash
# 运行一次即可安装；不需要 sudo，也不依赖 Oh My Zsh、Python 或 Node.js。
set -euo pipefail

usage() {
    cat <<'HELP'
easyCmd 安装器
用法：bash install_easyCmd.sh [--no-shell]

将本文件、easyCmd.zsh、load_easyCmd.zsh 放在同一目录后运行。
自动安装到 ~/.local/share/easyCmd，并备份、更新 ${ZDOTDIR:-$HOME}/.zshrc。
终端中安装完成后自动进入启用 easyCmd 的 zsh；--no-shell 只安装并退出。
不会安装系统软件或更改默认 Shell。目标电脑需要已安装 zsh。
HELP
}
no_shell=0
case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    --no-shell) no_shell=1 ;;
    '') ;;
    *) usage >&2; exit 2 ;;
esac
if (( $# > 1 )); then usage >&2; exit 2; fi

# 文件管理器执行脚本而没有终端时，自动在可用的终端模拟器中显示安装过程。
if (( ! no_shell )) && [[ ! -t 0 && -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} && ${EASYCMD_INSTALL_TERMINAL:-0} != 1 ]]; then
    export EASYCMD_INSTALL_TERMINAL=1
    installer_path=$0
    [[ $installer_path == /* ]] || installer_path=$PWD/$installer_path
    for terminal in x-terminal-emulator gnome-terminal konsole xterm; do
        if command -v "$terminal" >/dev/null 2>&1; then
            if [[ $terminal == gnome-terminal ]]; then exec "$terminal" -- bash "$installer_path"; fi
            exec "$terminal" -e bash "$installer_path"
        fi
    done
fi

fail() { printf 'easyCmd: %s\n' "$*" >&2; exit 1; }
[[ -n ${HOME:-} && -d $HOME ]] || fail 'HOME 目录不可用。'
zsh_bin=$(command -v zsh) || fail '未找到 zsh。请先安装 zsh，再运行本脚本。'
source_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
for file in easyCmd.zsh load_easyCmd.zsh; do
    [[ -r $source_dir/$file ]] || fail "安装包缺少 $file，请将三个安装文件放在一起。"
    "$zsh_bin" -dfn "$source_dir/$file" || fail "$file 语法检查失败，未更改配置。"
done

install_dir=$HOME/.local/share/easyCmd
config_dir=${ZDOTDIR:-$HOME}
mkdir -p -- "$config_dir"
rc=$config_dir/.zshrc
# 写入符号链接指向的文件，保留用户原有的配置链接。
if [[ -L $rc ]]; then rc=$("$zsh_bin" -dfc 'print -r -- ${1:A}' -- "$rc"); fi
[[ ! -e $rc || -f $rc ]] || fail '.zshrc 不是普通文件。'
mkdir -p -- "$(dirname -- "$rc")"
work=$(mktemp -d "$(dirname -- "$rc")/.easyCmd-install.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
if [[ -f $rc ]]; then cp -p -- "$rc" "$work/rc"; else : > "$work/rc"; fi

# 只替换本插件的加载行和本安装器管理的块；其他配置按原样保留且绝不执行。
cat > "$work/update.awk" <<'AWK'
BEGIN { inside=0; invalid=0 }
$0 == "# >>> easyCmd >>>" {
    if (inside) invalid=1
    inside=1
    next
}
$0 == "# <<< easyCmd <<<" {
    if (!inside) invalid=1
    inside=0
    next
}
inside { next }
/^[ \t]*(\[[ \t]+-[fr][ \t]+[^]]+\][ \t]*&&[ \t]*)?(source|\.)[ \t]+[^;#]+\/(history_fuzzy|rc_hf|easyCmd|load_easyCmd)\.zsh["']?[ \t]*(#.*)?$/ {
    print ": # easyCmd 由文件末尾的安装块加载"
    next
}
{ print }
END {
    if (inside || invalid) exit 3
    print "# >>> easyCmd >>>"
    print "[[ -r \"$HOME/.local/share/easyCmd/load_easyCmd.zsh\" ]] && source \"$HOME/.local/share/easyCmd/load_easyCmd.zsh\""
    print "# <<< easyCmd <<<"
}
AWK
input=/dev/null
[[ ! -f $rc ]] || input=$rc
awk -f "$work/update.awk" "$input" > "$work/rc" || fail '已有 easyCmd 配置块不完整，未更改配置。'
"$zsh_bin" -dfn "$work/rc" > "$work/syntax.log" 2>&1 || fail '合并后的 .zshrc 未通过语法检查，原配置未更改。请先检查原配置语法。'

# 校验完成后再写入安装目录；每个文件先完整复制，再原子替换。
mkdir -p -- "$install_dir"
for file in easyCmd.zsh load_easyCmd.zsh install_easyCmd.sh; do
    if [[ -f $install_dir/$file ]] && cmp -s -- "$source_dir/$file" "$install_dir/$file"; then continue; fi
    stage=$(mktemp "$install_dir/.install.XXXXXX")
    if ! cp -- "$source_dir/$file" "$stage"; then rm -f -- "$stage"; fail "无法复制 $file。"; fi
    if [[ $file == *.sh ]]; then chmod 755 "$stage"; else chmod 644 "$stage"; fi
    mv -f -- "$stage" "$install_dir/$file"
done
backup=''
if [[ -f $rc ]] && cmp -s -- "$rc" "$work/rc"; then
    printf 'easyCmd 配置已是最新，无需重复添加。\n'
else
    if [[ -f $rc ]]; then
        backup=$(mktemp "$rc.easyCmd.bak.XXXXXX")
        cp -p -- "$rc" "$backup"
    fi
    mv -f -- "$work/rc" "$rc"
fi
printf 'easyCmd 安装完成。\n安装目录：%s\nzsh 配置：%s\n' "$install_dir" "$rc"
[[ -z $backup ]] || printf '原配置备份：%s\n' "$backup"
printf '以后打开 zsh 会自动启用，无需执行 load_easyCmd.zsh。\n'
if (( ! no_shell )) && [[ -t 0 && -t 1 ]]; then
    printf '现在进入已配置的 zsh；输入 exit 可返回原终端会话。\n'
    rm -rf -- "$work"
    trap - EXIT
    exec "$zsh_bin" -i
fi
printf '当前窗口可运行：source "$HOME/.local/share/easyCmd/load_easyCmd.zsh"\n'
