#!/usr/bin/env zsh
# ============================================================
#  history_fuzzy.zsh  -  常驻式实时历史模糊下拉（zsh 原生）
#
#  行为：
#    * 在提示符行首输入任意字符（无空格）即自动列出匹配的历史命令
#    * 每敲一个键实时重算重排，最多 HIST_FUZZY_MAX_SHOW(默认10) 条
#    * 优先级：全词匹配 > 开头匹配 > 中间匹配 > 非连续(子序列)匹配
#      前三级内按「最近使用」排序；非连续组内按命令长度（匹配越紧凑越靠前）
#    * Enter 只执行当前输入行，下拉仅作参考（不会误执行历史命令）
#    * 需要选中：Ctrl-X h 打开 complist 菜单，方向键 + 回车 填入命令行
#    * 历史只扫描最近 HIST_FUZZY_MAX_HIST(默认1000) 条，避免资源/卡顿
#
#  渲染方式：PREDISPLAY（默认，向上延伸，列表在输入行上方，输入行永不被顶走）
#            或 POSTDISPLAY（向下，列表在输入行下方）
#            两者都由 zle 负责重绘与清除，不抢终端、不破坏回滚缓冲
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
: ${HIST_FUZZY_COLOR_FUZZY:=fg=black,bold}        # 非连续凑数项：更暗，一眼能区分
: ${HIST_FUZZY_PLACE:=above}                      # above=列表在输入行上方(默认) / below=下方
: ${HIST_FUZZY_FUZZY_MAX:=4}                      # 非连续(凑数)匹配最多补几条；设 0 = 完全不要
: ${HIST_FUZZY_FUZZY_MIN_LEN:=2}                  # 少于几个字符不做非连续匹配
typeset -ga HIST_FUZZY_IGNORE
(( ${#HIST_FUZZY_IGNORE} )) || HIST_FUZZY_IGNORE=(shl shh auto_history history_20)

# ---------- 内部状态 ----------
typeset -ga _hist_fuzzy_cache          # 历史缓存：最新在前，已去重
typeset -ga _hist_fuzzy_result         # 当前匹配结果
typeset -ga _hist_fuzzy_hl             # 本次添加的 region_highlight
typeset -g  _hist_fuzzy_last_histcmd=0
typeset -g  _hist_fuzzy_n_exact=0                # 前三级(真匹配)条数，其余为凑数项

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

  _hist_fuzzy_n_exact=${#all}                          # 前三级条数（渲染时用来区分凑数项）

  # 前三级不足 MAX_SHOW 条时才跑非连续匹配（最容易产生噪音的一步）
  if (( ${#all} < HIST_FUZZY_MAX_SHOW && ${#q} >= HIST_FUZZY_FUZZY_MIN_LEN )); then
    local -a cs ec=()
    cs=(${(s::)q})
    local c
    for c in $cs; do ec+=(${(b)c}); done
    # 注意：不能写成 ${~"*${(j:*:)ec}*"}，交互式 zsh 下嵌套带引号展开会 bad substitution
    local fpat="*${(j:*:)ec}*"
    m4=(${(M)_hist_fuzzy_cache:#${~fpat}})             # 非连续：buil -> *b*u*i*l*d*

    # 评分排序：① 匹配跨度越小越紧凑 ② 首个匹配字符越靠前越好 ③ 命令越短越好
    # 这样 "dmesg" 不会被 "sudo apt-get install ..." 之类的松散命中挤掉
    local -a tmp=()
    local k f l span
    for k in $m4; do
      f=${k[(i)${ec[1]}]}                              # 最左：首个查询字符的位置
      l=${k[(I)${ec[-1]}]}                             # 最右：末个查询字符的位置
      if (( l < f )); then span=999; else span=$(( l - f + 1 )); fi
      (( f > ${#k} )) && f=999
      tmp+=("${(l:3::0:)span}${(l:3::0:)f}${(l:4::0:)${#k}} $k")
    done
    m4=(${${(o)tmp}#* })

    # 凑数项最多补 HIST_FUZZY_FUZZY_MAX 条，避免一屏噪音
    local room=$(( HIST_FUZZY_MAX_SHOW - ${#all} ))
    (( room > HIST_FUZZY_FUZZY_MAX )) && room=$HIST_FUZZY_FUZZY_MAX
    m4=(${m4[1,room]})

    local -aU uall2
    uall2=($all $m4)
    all=($uall2)
  fi

  _hist_fuzzy_result=(${all[1,HIST_FUZZY_MAX_SHOW]})
  (( ${#_hist_fuzzy_result} ))
}

# ---------- 3. 渲染 ----------
_hist_fuzzy_clear() {
  PREDISPLAY=''
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

  # 屏幕高度不够时自动少显示几条（避免整屏被列表占满）
  local maxn=$(( ${LINES:-24} - 3 ))
  (( maxn < 1 )) && return 1
  (( ${#cands} > maxn )) && cands=(${cands[1,maxn]})

  local maxw=$(( ${COLUMNS:-80} - 1 ))
  local line off i=0 col
  local txt=''
  local -a hl=()

  if [[ $HIST_FUZZY_PLACE == below ]]; then
    # 向下：光标之后（列表在输入行下方）
    txt=$'\n'
    off=${#BUFFER}
    for line in $cands; do
      (( ${#line} > maxw )) && line="${line[1,maxw]}"
      txt+=$line$'\n'
      i=$(( i + 1 ))
      if (( i == 1 )); then col=$HIST_FUZZY_COLOR_TOP
      elif (( i <= _hist_fuzzy_n_exact )); then col=$HIST_FUZZY_COLOR_REST
      else col=$HIST_FUZZY_COLOR_FUZZY; fi
      hl+=("$(( off + 1 )) $(( off + 1 + ${#line} )) $col")
      off=$(( off + 1 + ${#line} ))
    done
    POSTDISPLAY=$txt
  else
    # 向上：提示符之后、输入行之前（列表在输入行上方，输入行不会被顶走）
    off=0
    for line in $cands; do
      (( ${#line} > maxw )) && line="${line[1,maxw]}"
      txt+=$line$'\n'
      i=$(( i + 1 ))
      if (( i == 1 )); then col=$HIST_FUZZY_COLOR_TOP
      elif (( i <= _hist_fuzzy_n_exact )); then col=$HIST_FUZZY_COLOR_REST
      else col=$HIST_FUZZY_COLOR_FUZZY; fi
      hl+=("$off $(( off + ${#line} )) $col")
      off=$(( off + ${#line} + 1 ))
    done
    PREDISPLAY=$txt
  fi

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
  _hist_fuzzy_clear                       # 菜单弹出前先收起列表，避免画面重叠
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
