#!/usr/bin/env zsh
# ============================================================
#  history_fuzzy.zsh  -  常驻式实时历史模糊下拉（zsh 原生）
#
#  行为：
#    * 在提示符行首输入任意字符（无空格）即自动在下方列出匹配的历史命令
#    * 每敲一个键实时重算重排，最多 HIST_FUZZY_MAX_SHOW(默认10) 条
#    * 优先级：全词匹配 > 开头匹配 > 中间匹配 > 非连续(子序列)匹配
#      前三级内按「最近使用」排序；非连续组内按命令长度（匹配越紧凑越靠前）
#    * Enter 只执行当前输入行，下拉仅作参考（不会误执行历史命令）
#    * 需要选中：Ctrl-X h 打开 complist 菜单，方向键 + 回车 填入命令行
#    * 历史只扫描最近 HIST_FUZZY_MAX_HIST(默认1000) 条，避免资源/卡顿
#
#  渲染方式：POSTDISPLAY（由 zle 负责重绘与清除，不抢终端、不破坏回滚）
#
#  可调参数（在 source 之前设置）：
#    HIST_FUZZY_MAX_HIST   扫描最近多少条历史（默认 1000）
#    HIST_FUZZY_MAX_SHOW   最多显示多少条（默认 10）
#    HIST_FUZZY_MIN_LEN    至少输入几个字符才触发（默认 1）
#    HIST_FUZZY_IGNORE     黑名单命令（按首个单词匹配）
#    HIST_FUZZY_COLOR_TOP  最佳匹配颜色（默认 fg=green,bold）
#    HIST_FUZZY_COLOR_REST 其余匹配颜色（默认 fg=blue）
# ============================================================

# 幂等：重复 source 不会重复注册部件
[[ -n $_HIST_FUZZY_LOADED ]] && return 0
typeset -g _HIST_FUZZY_LOADED=1

# ---------- 参数 ----------
: ${HIST_FUZZY_MAX_HIST:=1000}
: ${HIST_FUZZY_MAX_SHOW:=10}
: ${HIST_FUZZY_MIN_LEN:=1}
: ${HIST_FUZZY_COLOR_TOP:=fg=green,bold}
: ${HIST_FUZZY_COLOR_REST:=fg=blue}
typeset -ga HIST_FUZZY_IGNORE
(( ${#HIST_FUZZY_IGNORE} )) || HIST_FUZZY_IGNORE=(shl shh auto_history history_20)

# ---------- 内部状态 ----------
typeset -ga _hist_fuzzy_cache          # 历史缓存：最新在前，已去重
typeset -ga _hist_fuzzy_result         # 当前匹配结果
typeset -ga _hist_fuzzy_hl             # 本次添加的 region_highlight
typeset -g  _hist_fuzzy_last_histcmd=0

# ---------- 1. 历史缓存 ----------
_hist_fuzzy_refresh() {
  # 仅在历史真的增长时重建
  (( _hist_fuzzy_last_histcmd == ${HISTCMD:-0} && ${#_hist_fuzzy_cache} )) && return 0
  _hist_fuzzy_last_histcmd=${HISTCMD:-0}

  local -a h
  local first=1
  (( ${HISTCMD:-0} > HIST_FUZZY_MAX_HIST )) && first=$(( HISTCMD - HIST_FUZZY_MAX_HIST + 1 ))
  h=(${(f)"$(fc -l -n $first 2>/dev/null)"})          # 只取最近 N 条

  # 兜底：内存里不足 50 条时直接读历史文件（如 HISTSIZE 被设得很小）
  if (( ${#h} < 50 )) && [[ -n $HISTFILE && -f $HISTFILE ]]; then
    local -a raw h2=()
    raw=(${(f)"$(tail -n ${HIST_FUZZY_MAX_HIST} $HISTFILE 2>/dev/null)"})
    local x
    for x in $raw; do
      [[ $x =~ '^: [0-9]+:[0-9]+;' ]] && x=${x#*;}     # 去 extended history 前缀
      h2+=($x)
    done
    h=($h2)
  fi

  local -aU u
  u=(${(Oa)h})                                        # 最新在前 + 去重保留最新

  local -a out=()
  local x cmd0
  for x in $u; do
    x=${x%"${x##*[![:space:]]}"}                      # 去掉尾部空白（否则同一条命令算成两条）
    [[ -z ${x//[[:space:]]/} ]] && continue           # 空行
    [[ $x == [\|\&\;]* ]] && continue                 # 多行命令被拆出的续行片段
    [[ $x == *$'\\n'* ]] && continue                  # 多行命令（历史里存成字面 \n）
    cmd0=${x%% *}
    (( ${HIST_FUZZY_IGNORE[(I)${cmd0}]} )) && continue
    out+=($x)
  done
  _hist_fuzzy_cache=($out)
}

# ---------- 2. 四级模糊匹配 ----------
# 输入：LBUFFER；输出：_hist_fuzzy_result（最多 MAX_SHOW 条）
_hist_fuzzy_build() {
  _hist_fuzzy_result=()
  local q=$LBUFFER

  (( ${#_hist_fuzzy_cache} )) || _hist_fuzzy_refresh
  (( ${#q} < HIST_FUZZY_MIN_LEN )) && return 1
  [[ $q == *[[:space:]]* ]] && return 1               # 只在行首命令位置

  local qp=${(b)q}                                    # 转义 glob 特殊字符

  local -a m1 m2 m3 m4 all
  m1=(${(M)_hist_fuzzy_cache:#${~qp}})                # 全词
  m2=(${(M)_hist_fuzzy_cache:#${~qp}*})               # 开头
  m3=(${(M)_hist_fuzzy_cache:#*${~qp}*})              # 中间

  local -aU uall
  uall=($m1 $m2 $m3)
  all=($uall)

  # 前三级不足 MAX_SHOW 条时才跑非连续匹配（最贵的一步）
  if (( ${#all} < HIST_FUZZY_MAX_SHOW )); then
    local -a cs ec=()
    cs=(${(s::)q})
    local c
    for c in $cs; do ec+=(${(b)c}); done
    m4=(${(M)_hist_fuzzy_cache:#${~"*${(j:*:)ec}*"}}) # 非连续：buil -> *b*u*i*l*d*
    # 组内：命令越短 = 匹配越紧凑，优先
    local -a tmp=()
    local k
    for k in $m4; do tmp+=("${(l:6::0:)${#k}} $k"); done
    m4=(${${(o)tmp}#* })
    local -aU uall2
    uall2=($all $m4)
    all=($uall2)
  fi

  _hist_fuzzy_result=(${all[1,HIST_FUZZY_MAX_SHOW]})
  (( ${#_hist_fuzzy_result} ))
}

# ---------- 3. 渲染 ----------
_hist_fuzzy_clear() {
  POSTDISPLAY=''
  if (( ${#_hist_fuzzy_hl} )); then
    local -a keep=()
    local r
    for r in $region_highlight; do
      (( ${_hist_fuzzy_hl[(I)$r]} )) || keep+=($r)
    done
    region_highlight=($keep)
    _hist_fuzzy_hl=()
  fi
}

_hist_fuzzy_render() {
  local -a cands
  cands=($_hist_fuzzy_result)
  (( ${#cands} )) || return 1

  local maxw=$(( ${COLUMNS:-80} - 1 ))
  local line off=${#BUFFER} i=0
  local txt=$'\n'
  local -a hl=()

  for line in $cands; do
    (( ${#line} > maxw )) && line="${line[1,maxw]}"
    txt+=$line$'\n'
    i=$(( i + 1 ))
    if (( i == 1 )); then
      hl+=("$(( off + 1 )) $(( off + 1 + ${#line} )) $HIST_FUZZY_COLOR_TOP")
    else
      hl+=("$(( off + 1 )) $(( off + 1 + ${#line} )) $HIST_FUZZY_COLOR_REST")
    fi
    off=$(( off + 1 + ${#line} ))
  done

  POSTDISPLAY=$txt
  region_highlight+=($hl)
  _hist_fuzzy_hl=($hl)
}

# ---------- 4. 触发 ----------
_hist_fuzzy_trigger() {
  _hist_fuzzy_refresh                     # 历史增长时才真正重建，平时一次整数比较返回
  _hist_fuzzy_clear
  if [[ -n $LBUFFER \
     && $LBUFFER != *[[:space:]]* \
     && ${#LBUFFER} -ge $HIST_FUZZY_MIN_LEN ]] && _hist_fuzzy_build; then
    _hist_fuzzy_render
  fi
  return 0
}

# ---------- 5. 补全函数（Ctrl-X h 菜单用） ----------
_hist_fuzzy_complete() {
  _hist_fuzzy_build || return 1
  (( ${#_hist_fuzzy_result} )) || return 1
  compadd -Q -o nosort -V history -a _hist_fuzzy_result
}

# ---------- 6. 部件注册（仅交互环境） ----------
if [[ -o interactive ]] && zle -l >/dev/null 2>&1; then
  zmodload zsh/complist 2>/dev/null
  autoload -Uz _generic 2>/dev/null

  zle -C hist-fuzzy-menu menu-select _generic
  zstyle ':completion:hist-fuzzy-menu:*' completer _hist_fuzzy_complete
  zstyle ':completion:hist-fuzzy-menu:*' matcher-list ''
  zstyle ':completion:hist-fuzzy-menu:*' format '%F{blue}history%f'
  bindkey -M emacs '^Xh' hist-fuzzy-menu 2>/dev/null
  bindkey -M viins '^Xh' hist-fuzzy-menu 2>/dev/null

  # 用 zle-line-pre-redraw 钩子：行每次重绘都刷新下拉
  # （不包装 self-insert 等部件，避免被 zsh-syntax-highlighting 之类的插件覆盖）
  _hist_fuzzy_prev_preredraw=${${widgets[zle-line-pre-redraw]}#user:}
  [[ $_hist_fuzzy_prev_preredraw == builtin ]] && _hist_fuzzy_prev_preredraw=''

  _hist_fuzzy_pre_redraw() {
    [[ -n $_hist_fuzzy_prev_preredraw ]] && zle $_hist_fuzzy_prev_preredraw
    _hist_fuzzy_trigger
  }
  zle -N zle-line-pre-redraw _hist_fuzzy_pre_redraw
fi

_hist_fuzzy_refresh
