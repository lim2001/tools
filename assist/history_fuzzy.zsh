#!/usr/bin/env zsh
# 历史实时下拉：输入行下方最多 10 条（HIST_FUZZY_MAX_SHOW 可设为 15）。
# Tab/→ 默认保留输入行原有补全；先按 ↑/↓ 选择历史项后，Tab/→ 才填该项。
# Alt-1..9 直接填历史项；Ctrl-G 收起；主动选择历史项后回车填入并执行该项，
# 未主动选择或已返回输入行编辑时，回车只执行 BUFFER。
# 列表出现后自动接收鼠标：左键单击历史项即可执行，不需要额外快捷键。
# Esc、viins、emacs、main、vicmd 的原生绑定均不改写。
#
# 下拉渲染用 ZLE 的 POSTDISPLAY 和 region_highlight；仅点击时查询首项位置，
# 不改 PROMPT/PREDISPLAY、不排入伪按键。ZLE 负责折行、清除和差分重绘。
# Ctrl-C 绕过 ZLE 结束钩子时，下一提示符前按已知列表行数相对清除残留。
# POSTDISPLAY 的列表后缀在委托原生部件前摘除，灰字建议仍由原插件管理。
# 私有键表复制当前绑定，包装器以原部件名调用，补全/vi/插件仍走原来的路径。
# 建议在 oh-my-zsh、autosuggestions、syntax-highlighting 之后 source。
# 从旧实验版升级请新开 shell；旧版已经覆盖的键和部件无法可靠逆推恢复。
#
# 匹配优先级：全词 > 前缀 > 词首 > 子串 > 缩写 > 多词 > 紧凑子序列。
# 同级按下面的独立评分维度排序，同分按最近使用排序。
# 追加维度：_hist_fuzzy_dim_add name weight '代码；结果放 _hist_fuzzy_dim_val'

[[ -o interactive && -o zle ]] || return 0
(( ${_HIST_FUZZY_VERSION:-0} >= 17 )) && return 0
if (( ${_HIST_FUZZY_VERSION:-0} > 0 && _HIST_FUZZY_VERSION < 13 )); then
  print -u2 -- 'history_fuzzy: 请新开 zsh 加载新版，以清除旧版覆盖的部件。'
  return 1
fi
typeset -g _HIST_FUZZY_VERSION=17
zmodload zsh/parameter
zmodload zsh/zleparameter
zmodload zsh/zselect
zmodload zsh/datetime
autoload -Uz add-zle-hook-widget add-zsh-hook

: ${HIST_FUZZY_MAX_HIST:=10000}
: ${HIST_FUZZY_MAX_SHOW:=10}
: ${HIST_FUZZY_MIN_LEN:=1}
: ${HIST_FUZZY_COLOR_MATCH:=fg=green,bold}
: ${HIST_FUZZY_COLOR_HOVER:=bg=cyan,fg=black}
: ${HIST_FUZZY_FUZZY_MAX:=4}
: ${HIST_FUZZY_FUZZY_MIN_LEN:=2}
: ${HIST_FUZZY_SPAN_SLACK:=3}
# 每级只精排最近的一批；限制逐字符路径的开销，仍可按需调大。
: ${HIST_FUZZY_SCORE_LIMIT:=80}
: ${HIST_FUZZY_LOOSE_LIMIT:=40}
: ${HIST_FUZZY_BASE_SCORE:=100000}
typeset -ga HIST_FUZZY_IGNORE
(( ${#HIST_FUZZY_IGNORE} )) || HIST_FUZZY_IGNORE=(shl shh auto_history history_20)
typeset -ga _hist_fuzzy_cache=() _hist_fuzzy_result=() _hist_fuzzy_hits=()
typeset -ga _hist_fuzzy_qpat=() _hist_fuzzy_qchr=() _hist_fuzzy_toks=()
typeset -g _hist_fuzzy_cand='' _hist_fuzzy_first=0 _hist_fuzzy_span=0
typeset -g _hist_fuzzy_sc=0 _hist_fuzzy_wn=0 _hist_fuzzy_wv=0

# zsh 自己读取 HISTFILE；这里只取内存历史，保持命令的引号和空白原样。
# 不拆多行命令，避免把其中一行误当成独立可执行的历史项。
_hist_fuzzy_refresh() {
  emulate -L zsh
  setopt extendedglob
  local event cmd first
  local -a events=("${(@Onk)history}")
  local -A seen=()
  _hist_fuzzy_cache=()
  for event in "${(@)events[1,HIST_FUZZY_MAX_HIST]}"; do
    cmd=$history[$event]
    [[ -z ${cmd//[[:space:]]/} || $cmd == *[[:cntrl:]]* ]] && continue
    first=${${cmd##[[:space:]]#}%% *}
    (( ${HIST_FUZZY_IGNORE[(Ie)$first]} )) && continue
    [[ -n ${seen[$cmd]-} ]] && continue
    seen[$cmd]=1
    _hist_fuzzy_cache+=("$cmd")
  done
  _hist_fuzzy_query=$'\0'
  return 0
}
# 维度注册：$1=维度名  $2=默认权重
typeset -ga _hist_fuzzy_dims                    # 维度名列表（顺序无关）
typeset -gA _hist_fuzzy_dim_wv                  # 维度名 -> 权重变量名
typeset -gA _hist_fuzzy_dim_code                # 维度名 -> 打分代码片段
_hist_fuzzy_dims=()
_hist_fuzzy_dim_wv=()
_hist_fuzzy_dim_code=()
typeset -g  _hist_fuzzy_dim_val=0               # 维度函数的输出

# 注册一个维度：
#   $1=维度名  $2=默认权重  $3=打分代码片段（推荐，编译后零函数调用开销）
# 不传 $3 时退化为「调用 _hist_fuzzy_dim_<名> 函数」的写法（方便，但每候选多一次调用）
#
# ⚠ 片段里的局部变量请统一加「维度名_」前缀！
#   所有维度的片段会被编译进同一个函数，而 zsh 对 functions[name]="..." 定义的
#   函数里「同一个变量名被 local 两次」会把旧值打印到 stdout（这是血泪教训：
#   屏幕上一堆 k=3 / sc=502823 就是这么来的）。用前缀隔开就不会撞名。
_hist_fuzzy_dim_add() {
  local name=$1 w=$2 code=$3 var=HIST_FUZZY_W_${1:u}
  (( ${_hist_fuzzy_dims[(I)$name]} )) || _hist_fuzzy_dims+=($name)
  _hist_fuzzy_dim_wv[$name]=$var
  (( ${(P)+var} )) || typeset -g $var=$w             # 未定义时才设默认值
  [[ -n $code ]] && _hist_fuzzy_dim_code[$name]=$code
  _hist_fuzzy_dim_compile
  return 0
}

# 把所有维度的片段拼成一个函数，打分时只需要一次函数调用。
# 用 functions[...]= 而不是 eval：这样片段里的 $变量 不会被二次展开。
_hist_fuzzy_dim_compile() {
  local d body='' nl=$'\n'
  for d in $_hist_fuzzy_dims; do
    if [[ -n ${_hist_fuzzy_dim_code[$d]} ]]; then
      body+="    _hist_fuzzy_dim_val=0${nl}${_hist_fuzzy_dim_code[$d]}${nl}"
      body+="    (( sc += _hist_fuzzy_dim_val * \$HIST_FUZZY_W_${d:u} ))${nl}"
    else
      body+="    _hist_fuzzy_dim_val=0${nl}"
      body+="    _hist_fuzzy_dim_${d} 2>/dev/null && (( sc += _hist_fuzzy_dim_val * \$HIST_FUZZY_W_${d:u} ))${nl}"
    fi
  done
  functions[_hist_fuzzy_score_impl]="
  local sc=\$HIST_FUZZY_BASE_SCORE
$body  _hist_fuzzy_sc=\$sc
  return 0
"
}

# ---- 内置维度（正分 = 加分项）----
# 以「代码片段」注册，编译时被拼进 _hist_fuzzy_score_impl，没有函数调用开销。
# 片段里可直接用 $_hist_fuzzy_hits / $_hist_fuzzy_cand / $_hist_fuzzy_toks 等变量。

# 相邻命中：连续段越长说明查询串越完整
_hist_fuzzy_dim_add consec 2000 '
  local consec_k consec_v=0
  for (( consec_k = 2; consec_k <= ${#_hist_fuzzy_hits}; consec_k++ )); do
    (( _hist_fuzzy_hits[consec_k] == _hist_fuzzy_hits[consec_k-1] + 1 )) && (( consec_v += 1 ))
  done
  _hist_fuzzy_dim_val=$consec_v'

# 命中字符落在单词边界（分隔符之后）或行首：语义相关性更强
_hist_fuzzy_dim_add bound 1000 '
  local bound_k bound_v=0 bound_pc
  for bound_k in $_hist_fuzzy_hits; do
    if (( bound_k == 1 )); then
      (( bound_v += 2 ))                             # 行首加倍
    else
      bound_pc=${_hist_fuzzy_cand[bound_k-1]}
      [[ -z $bound_pc || $bound_pc != [[:alnum:]_.] ]] && (( bound_v += 1 ))
    fi
  done
  _hist_fuzzy_dim_val=$bound_v'

# 查询里的「空格」命中了候选里的空格 —— 说明两边分词结构对齐
_hist_fuzzy_dim_add space 1500 '
  local space_k space_v=0
  for (( space_k = 1; space_k <= ${#_hist_fuzzy_qchr}; space_k++ )); do
    [[ $_hist_fuzzy_qchr[space_k] == " " ]] && (( space_v += 1 ))
  done
  _hist_fuzzy_dim_val=$space_v'

# 查询里的标点命中了候选里的标点 —— 路径 / 选项结构对齐
_hist_fuzzy_dim_add punct 800 '
  local punct_k punct_v=0 punct_c
  for (( punct_k = 1; punct_k <= ${#_hist_fuzzy_qchr}; punct_k++ )); do
    punct_c=$_hist_fuzzy_qchr[punct_k]
    [[ $punct_c != [[:alnum:]] && $punct_c != " " ]] && (( punct_v += 1 ))
  done
  _hist_fuzzy_dim_val=$punct_v'

# ---- 词级缩写匹配（b k -> build kernel，d mes -> dmesg）----
# 查询词按顺序去「消耗」候选的单词：每个查询词必须是某个单词开头（或某个单词
# 被前一个查询词吃掉一部分后剩余部分）的前缀；允许一个单词被多个查询词连续吃。
# 输出：_hist_fuzzy_wn = 命中的查询词数
#       _hist_fuzzy_wv = 2*命中数 - 中途跳过的单词数（跳词越多说明匹配越散乱）
typeset -g  _hist_fuzzy_wm_cand=$'\0'             # 单词拆分缓存：同一个候选只算一次
_hist_fuzzy_words_match() {
  local cand=$1
  local -a cw
  # 打分时要算一次、分级判定又要算一次 → 结果缓存起来（两者总是同一候选连续调用）
  [[ $cand == $_hist_fuzzy_wm_cand ]] && return 0
  _hist_fuzzy_wm_cand=$cand
  cw=(${=cand//[^[:alnum:]]/ })                   # "./build.sh kernel" -> build sh kernel
  local wi=1 rem='' t
  local -i found hits=0 skip=0
  for t in $_hist_fuzzy_toks; do
    found=0
    while (( wi <= ${#cw} )); do
      [[ -z $rem ]] && rem=${(L)cw[wi]}
      if [[ $rem == ${(L)t}* ]]; then
        rem=${rem[$(( ${#t} + 1 )),-1]}
        found=1
        break
      fi
      (( skip += 1 )); (( wi += 1 )); rem=''
    done
    (( found )) || break
    (( hits += 1 ))
  done
  _hist_fuzzy_wn=$hits
  _hist_fuzzy_wv=$(( hits * 2 - skip ))
}

# 缩写：命中了几个查询词（带散乱惩罚）
_hist_fuzzy_dim_add abbrev 4000 '
  if (( ${#_hist_fuzzy_toks} > 1 )); then
    _hist_fuzzy_words_match $_hist_fuzzy_cand
    _hist_fuzzy_dim_val=$_hist_fuzzy_wv
  fi'

# ---- 内置维度（负分 = 惩罚项）----
_hist_fuzzy_dim_add span 50 '_hist_fuzzy_dim_val=$(( - $_hist_fuzzy_span ))'
_hist_fuzzy_dim_add pos  20 '_hist_fuzzy_dim_val=$(( - $_hist_fuzzy_first ))'
_hist_fuzzy_dim_add len  1  '_hist_fuzzy_dim_val=$(( - ${#_hist_fuzzy_cand} ))'

# 候选是否为查询的完整缩写（所有查询词都被消耗掉）→ 供分级使用
_hist_fuzzy_is_abbrev() {
  (( ${#_hist_fuzzy_toks} > 1 )) || return 1
  _hist_fuzzy_words_match $1
  (( _hist_fuzzy_wn == ${#_hist_fuzzy_toks} ))
}

# 打分主体：一次字符扫描 + 遍历维度
# 输出：全局 _hist_fuzzy_sc（分数，越大越好）/ _hist_fuzzy_span
#       返回 0 = 命中所有查询字符，1 = 不是子序列
_hist_fuzzy_score() {
  local cand=$1
  local -a qp qc hits=()
  qp=($_hist_fuzzy_qpat)                             # 查询字符（已转义成 pattern）
  qc=($_hist_fuzzy_qchr)                             # 查询字符（原样）
  local rest=$cand pat
  local -i abs=0 p prev=0 first=0 last=0 ok=1 i=0

  for (( i = 1; i <= ${#qp}; i++ )); do
    pat=$qp[i]
    p=${rest[(i)$pat]}                               # 剩余串中下一个查询字符的位置
    (( p > ${#rest} )) && { ok=0; break; }           # 有字符找不到 → 非子序列
    abs=$(( abs + p ))
    hits+=($abs)
    (( i == 1 )) && first=$abs
    last=$abs
    rest=${rest[p+1,-1]}
  done
  (( ok )) || return 1

  _hist_fuzzy_cand=$cand
  _hist_fuzzy_hits=($hits)
  _hist_fuzzy_first=$first
  _hist_fuzzy_span=$(( last - first + 1 ))

  _hist_fuzzy_score_impl                # 编译好的评分函数：把所有维度跑一遍
  return 0
}


# 先分级再评分；每级有独立预算，常见前缀不必跑昂贵的模糊扫描。
_hist_fuzzy_build() {
  emulate -L zsh
  setopt extendedglob
  local q=$1 cand name pat text word score
  local -i level budget idx count=0
  local -a exact prefix boundary substr abbrev multi fuzzy group ranked
  local -A seen
  _hist_fuzzy_result=()
  q=${${q##[[:space:]]#}%%[[:space:]]#}
  (( ${#q} >= HIST_FUZZY_MIN_LEN && HIST_FUZZY_MAX_SHOW > 0 )) || return 0
  [[ $q == *[[:cntrl:]]* ]] && return 0
  _hist_fuzzy_qchr=("${(@s::)q}")
  _hist_fuzzy_qpat=()
  for text in "${_hist_fuzzy_qchr[@]}"; do _hist_fuzzy_qpat+=("${(b)text}"); done
  _hist_fuzzy_toks=(${=q})
  _hist_fuzzy_wm_cand=$'\0'
  pat="*${(j:*:)_hist_fuzzy_qpat}*"
  substr=("${(@M)_hist_fuzzy_cache:#*${q}*}")
  for cand in "${substr[@]}"; do
    if [[ $cand == "$q" ]]; then exact+=("$cand")
    elif [[ $cand == "$q"* ]]; then prefix+=("$cand")
    elif [[ $cand == *[^[:alnum:]_.]"$q"* ]]; then boundary+=("$cand")
    fi
  done
  for level in {0..6}; do
    case $level in
      0) group=("${exact[@]}") ;;
      1) group=("${prefix[@]}") ;;
      2) group=("${boundary[@]}") ;;
      3) group=("${substr[@]}") ;;
      4)
        (( ${#_hist_fuzzy_toks} > 1 )) || continue
        group=()
        for cand in "${_hist_fuzzy_cache[@]}"; do
          [[ -n ${seen[$cand]-} || $cand != ${~pat} ]] && continue
          if _hist_fuzzy_is_abbrev "$cand"; then group+=("$cand")
          else multi+=("$cand"); fi
        done ;;
      5) group=("${multi[@]}") ;;
      6)
        (( ${#q} >= HIST_FUZZY_FUZZY_MIN_LEN && HIST_FUZZY_FUZZY_MAX > 0 )) || continue
        group=("${(@M)_hist_fuzzy_cache:#${~pat}}") ;;
    esac
    budget=$HIST_FUZZY_SCORE_LIMIT
    (( level >= 4 || ${#q} <= 2 )) && budget=$HIST_FUZZY_LOOSE_LIMIT
    ranked=()
    idx=0
    for cand in "${group[@]}"; do
      [[ -n ${seen[$cand]-} ]] && continue
      (( ++idx > budget )) && break
      _hist_fuzzy_score "$cand" || continue
      (( level == 6 && _hist_fuzzy_span > ${#q} + HIST_FUZZY_SPAN_SLACK )) && continue
      score=$_hist_fuzzy_sc
      # 数值排序，索引补数保证同分时最新历史优先。
      ranked+=("$(( score * (HIST_FUZZY_MAX_HIST + 1) + HIST_FUZZY_MAX_HIST - idx )) $cand")
    done
    count=0
    for text in "${(@On)ranked}"; do
      cand=${text#* }
      seen[$cand]=1
      _hist_fuzzy_result+=("$cand")
      (( ${#_hist_fuzzy_result} >= HIST_FUZZY_MAX_SHOW )) && return 0
      (( level == 6 && ++count >= HIST_FUZZY_FUZZY_MAX )) && break
    done
  done
  return 0
}

typeset -g _hist_fuzzy_suffix='' _hist_fuzzy_query=$'\0' _hist_fuzzy_base=main
typeset -g _hist_fuzzy_retired_suffix=''
typeset -g _hist_fuzzy_mouse_enabled=0 _hist_fuzzy_mouse_pressed=0
typeset -g _hist_fuzzy_mouse_buffer='' _hist_fuzzy_mouse_command=''
typeset -g _hist_fuzzy_mouse_first=0 _hist_fuzzy_mouse_size=''
typeset -g _hist_fuzzy_suppressed='' _hist_fuzzy_closed=0 _hist_fuzzy_hover=1
typeset -g _hist_fuzzy_engaged=0 _hist_fuzzy_selection_cursor=0
typeset -g _hist_fuzzy_busy=0 _hist_fuzzy_active=0
typeset -ga _hist_fuzzy_shown=()
typeset -ga _hist_fuzzy_highlights=()
typeset -gA _hist_fuzzy_maps=()

# 只摘掉自己的后缀和高亮；autosuggestions 异步替换 POSTDISPLAY 时不回写旧建议。
_hist_fuzzy_detach() {
  local entry
  local -a keep=()
  local -A owned=()
  if [[ -n $_hist_fuzzy_suffix && $POSTDISPLAY == *"$_hist_fuzzy_suffix" ]]; then
    POSTDISPLAY=${POSTDISPLAY%"$_hist_fuzzy_suffix"}
  fi
  [[ -n $_hist_fuzzy_suffix ]] && _hist_fuzzy_retired_suffix=$_hist_fuzzy_suffix
  _hist_fuzzy_suffix=''
  for entry in "${_hist_fuzzy_highlights[@]}"; do owned[$entry]=1; done
  for entry in "${region_highlight[@]}"; do
    [[ -n ${owned[$entry]-} ]] || keep+=("$entry")
  done
  region_highlight=("${keep[@]}")
  _hist_fuzzy_highlights=()
  return 0
}

_hist_fuzzy_update() {
  emulate -L zsh
  if (( _hist_fuzzy_closed )); then
    [[ $BUFFER == "$_hist_fuzzy_suppressed" ]] && { _hist_fuzzy_shown=(); return 0; }
    _hist_fuzzy_closed=0
  fi
  if [[ $BUFFER != "$_hist_fuzzy_query" ]]; then
    _hist_fuzzy_query=$BUFFER
    _hist_fuzzy_build "$BUFFER"
    _hist_fuzzy_hover=1
    _hist_fuzzy_engaged=0
  fi
  # 光标回到输入行编辑后，Tab/→ 恢复原生含义；探针/重绘不改变选择。
  (( CURSOR != _hist_fuzzy_selection_cursor )) && _hist_fuzzy_engaged=0
  if (( ! ${#_hist_fuzzy_result} )); then _hist_fuzzy_shown=(); return 0; fi
  local part
  local -i n=$(( LINES - 3 ))
  for part in "${(@f)${:-"$BUFFER$POSTDISPLAY"}}"; do
    (( n -= ${(m)#part} / (COLUMNS > 0 ? COLUMNS : 80) + 1 ))
  done
  if (( n < 1 || COLUMNS < 8 )); then _hist_fuzzy_shown=(); return 0; fi
  _hist_fuzzy_shown=("${(@)_hist_fuzzy_result[1,n]}")
  (( _hist_fuzzy_hover > ${#_hist_fuzzy_shown} )) && _hist_fuzzy_hover=1
  return 0
}

_hist_fuzzy_draw() {
  (( _hist_fuzzy_busy || ! _hist_fuzzy_active )) && return 0
  [[ $KEYMAP == hf-map-* && $_hist_fuzzy_base != vicmd ]] || return 0
  _hist_fuzzy_compose
}

_hist_fuzzy_compose() {
  emulate -L zsh
  _hist_fuzzy_detach
  (( PENDING || KEYS_QUEUED_COUNT )) && return 0
  _hist_fuzzy_update
  (( ${#_hist_fuzzy_shown} )) || { _hist_fuzzy_mouse_off; return 0; }
  local line row colour
  local -i i=0 off pos limit=$(( COLUMNS - 1 )) start=${#region_highlight} run end
  # 保留输入和建议的折行空间；很小的终端直接少画几条。
  (( limit >= 8 )) || return 0
  for line in "${_hist_fuzzy_shown[@]}"; do
    (( ++i ))
    # (m) 按屏幕单元格裁剪和填充；不展开历史中的 %、$() 等文本。
    if (( ${(m)#line} > limit - 3 )); then
      line="${(mr:$((limit - 4)):)line}…"
    fi
    row="${(l:2::0:)i} $line"
    row=${(mr:limit:)row}
    off=$(( ${#BUFFER} + ${#POSTDISPLAY} + ${#_hist_fuzzy_suffix} + 1 ))
    _hist_fuzzy_suffix+=$'\n'$row
    colour=fg=default,bg=default
    (( i == _hist_fuzzy_hover )) && colour=$HIST_FUZZY_COLOR_HOVER
    region_highlight+=("$off $((off + ${#row})) $colour memo=history-fuzzy")
    _hist_fuzzy_score "$_hist_fuzzy_shown[i]"
    colour=$HIST_FUZZY_COLOR_MATCH
    (( i == _hist_fuzzy_hover )) && colour="$HIST_FUZZY_COLOR_HOVER,$colour"
    run=0 end=0
    for pos in "${_hist_fuzzy_hits[@]}" 0; do
      if (( pos != end + 1 || pos > ${#line} )); then
        (( run )) && region_highlight+=("$((off + 2 + run)) $((off + 3 + end)) $colour memo=history-fuzzy")
        run=0
      fi
      (( !pos || pos > ${#line} )) && break
      (( run )) || run=$pos
      end=$pos
    done
  done
  POSTDISPLAY+=$_hist_fuzzy_suffix
  _hist_fuzzy_highlights=("${(@)region_highlight[start+1,-1]}")
  _hist_fuzzy_mouse_on
  return 0
}

_hist_fuzzy_dismiss() {
  _hist_fuzzy_mouse_off
  _hist_fuzzy_detach
  _hist_fuzzy_closed=1
  _hist_fuzzy_suppressed=$BUFFER
  _hist_fuzzy_engaged=0
  _hist_fuzzy_shown=()
  return 0
}

# 私有键表中的所有部件先摘列表，再委托原来的部件（包括 Ctrl-F 等建议接受键）。
# zle -w 保留原生 WIDGET 名；执行期间还原 KEYMAP，兼容 vi-mode 的模式判断。
_hist_fuzzy_dispatch() {
  _hist_fuzzy_call "${WIDGET#hf-call:}" "$@"
}

_hist_fuzzy_call() {
  _hist_fuzzy_mouse_pressed=0
  local original=$1 ret=0 hf_before_buffer=$BUFFER hf_before_cursor=$CURSOR
  shift
  local -i completion=0
  _hist_fuzzy_detach
  [[ $original == *complete* || $original == *expand* || $original == *list-choices* ||
     ${widgets[$original]-} == completion:* ]] && completion=1
  (( completion )) && _hist_fuzzy_dismiss
  _hist_fuzzy_busy=1
  zle -K "$_hist_fuzzy_base"
  {
    _hist_fuzzy_busy=2
    zle "$original" -w -- "$@"
    ret=$?
  } always {
    _hist_fuzzy_busy=1
    # 连续输入可能跳过中间帧；即使后续退格把文字恢复原样，编辑也应退出列表选择。
    if [[ $BUFFER != "$hf_before_buffer" ]] || (( CURSOR != hf_before_cursor )); then
      _hist_fuzzy_engaged=0
    fi
    if (( completion )); then _hist_fuzzy_suppressed=$BUFFER; fi
    if [[ $KEYMAP == "$_hist_fuzzy_base" ]] && (( _hist_fuzzy_active )); then
      zle -K "${_hist_fuzzy_maps[$_hist_fuzzy_base]}"
    fi
    _hist_fuzzy_busy=0
    _hist_fuzzy_select
  }
  return $ret
}

_hist_fuzzy_key() {
  _hist_fuzzy_mouse_pressed=0
  emulate -L zsh
  local action=${WIDGET#hist-fuzzy-}
  local -i idx
  _hist_fuzzy_detach
  _hist_fuzzy_update
  # 默认青色行只是预览；主动选择后 Tab/→ 填入，Enter 填入并执行。
  if (( ${#_hist_fuzzy_shown} )) &&
     { [[ $action != tab && $action != right && $action != enter ]] || (( _hist_fuzzy_engaged )); }; then
    case $action in
      up|down)
        _hist_fuzzy_engaged=1
        _hist_fuzzy_selection_cursor=$CURSOR
        if [[ $action == up ]]; then
          (( _hist_fuzzy_hover = (_hist_fuzzy_hover + ${#_hist_fuzzy_shown} - 2) % ${#_hist_fuzzy_shown} + 1 ))
        else
          (( _hist_fuzzy_hover = _hist_fuzzy_hover % ${#_hist_fuzzy_shown} + 1 ))
        fi ;;
      cancel) _hist_fuzzy_dismiss ;;
      tab|right|enter|pick-*)
        idx=$_hist_fuzzy_hover
        [[ $action == pick-* ]] && idx=${action#pick-}
        if (( idx <= ${#_hist_fuzzy_shown} )); then
          BUFFER=$_hist_fuzzy_shown[idx]
          CURSOR=${#BUFFER}
          POSTDISPLAY=''
          _hist_fuzzy_dismiss
        fi ;;
    esac
    # 回车继续调用原来的绑定；填入、收起已完成，原生接受部件只执行一次。
    [[ $action == enter ]] || return 0
  fi
  # 未主动选择（即使有列表）也按当前原生绑定执行，包括用户自定义的灰字接受键。
  _hist_fuzzy_native_key "$KEYS" "$@"
}

_hist_fuzzy_native_key() {
  local key=$1 binding original
  local -a words
  shift
  binding=$(bindkey -L -M "$_hist_fuzzy_base" "$key")
  words=("${(@z)binding}")
  if (( ${words[(Ie)-s]} )); then
    zle -U -- "${(g:ce:)${(Q)words[-1]}}"
    return 0
  fi
  original=${(Q)words[-1]}
  _hist_fuzzy_call "$original" "$@"
}

# 下拉出现即接管鼠标；收起、补全、vicmd、执行和 Ctrl-C 后释放。
_hist_fuzzy_mouse_on() {
  (( _hist_fuzzy_mouse_enabled )) && return 0
  [[ -n ${terminfo[cup]} ]] || return 0
  print -rn -- $'\e[?1000h\e[?1006h' > /dev/tty
  _hist_fuzzy_mouse_enabled=1
}

_hist_fuzzy_mouse_off() {
  _hist_fuzzy_mouse_pressed=0
  (( _hist_fuzzy_mouse_enabled )) || return 0
  print -rn -- $'\e[?1000l\e[?1006l' > /dev/tty
  _hist_fuzzy_mouse_enabled=0
}

_hist_fuzzy_mouse_read() {
  (( PENDING || KEYS_QUEUED_COUNT )) || zselect -t 2 -r $hf_fd || return 1
  IFS= read -rk1 hf_char
}

# 读取 CSI 前缀之后的参数，不将终端回报当作输入文字；也消费迟到的回报。
_hist_fuzzy_mouse_packet() {
  local -F deadline=$(( EPOCHREALTIME + 0.3 ))
  local -i hf_valid=1
  hf_packet=''
  while (( EPOCHREALTIME < deadline && ${#hf_packet} < 32 )); do
    _hist_fuzzy_mouse_read || continue
    if [[ $hf_char == [0-9\;] ]]; then
      hf_packet+=$hf_char
    elif [[ $1 == *"$hf_char"* ]]; then
      hf_packet+=$hf_char
      (( hf_valid ))
      return
    elif [[ $hf_char == [[:print:]] ]]; then
      hf_valid=0
    else
      zle -U -- "$hf_char"
      return 1
    fi
  done
  return 1
}

_hist_fuzzy_cursor_report() {
  emulate -L zsh
  local hf_fd hf_char hf_packet
  exec {hf_fd}</dev/tty || return 0
  { _hist_fuzzy_mouse_packet R } always { exec {hf_fd}<&- }
  return 0
}

# 用 ZLE 自己的布局定位首项，兼容多行提示符、折行、中文和灰字。
# 临时把完全相同的显示文本交给 BUFFER，仅移动隐藏的光标；请求发出后立即
# 恢复原 BUFFER/CURSOR/POSTDISPLAY，再等待回报。绝不运行接受/编辑部件。
# DEC 私有 CPR (?6n) 不与 F3 / Ctrl-方向键冲突；无回报时不猜行号执行。
_hist_fuzzy_mouse_origin() {
  local hf_saved_buffer=$BUFFER hf_saved_post=$POSTDISPLAY hf_saved_cursor=$CURSOR
  local -a hf_saved_highlights=("${region_highlight[@]}")
  local hf_input='' hf_replay='' hf_busy=$_hist_fuzzy_busy
  local MATCH
  local -i MBEGIN MEND
  local -a match mbegin mend
  local -F deadline=$(( EPOCHREALTIME + 0.4 ))
  hf_first=0
  _hist_fuzzy_busy=1
  {
    print -rn -u $hf_fd -- $'\e[?25l'
    BUFFER+=$POSTDISPLAY
    POSTDISPLAY=''
    CURSOR=$(( ${#hf_saved_buffer} + ${#hf_saved_post} - ${#_hist_fuzzy_suffix} + 1 ))
    zle -R
    print -rn -u $hf_fd -- $'\e[?6n'
  } always {
    BUFFER=$hf_saved_buffer POSTDISPLAY=$hf_saved_post CURSOR=$hf_saved_cursor
    region_highlight=("${hf_saved_highlights[@]}")
    zle -R
    print -rn -u $hf_fd -- $'\e[?25h'
    _hist_fuzzy_busy=$hf_busy
  }
  while (( EPOCHREALTIME < deadline && ${#hf_input} < 1024 )); do
    _hist_fuzzy_mouse_read || continue
    hf_input+=$hf_char
    if [[ $hf_input =~ $'\e''\[\?([0-9]{1,5});([0-9]{1,5})(;[0-9]{1,5})?R' ]]; then
      hf_first=$((10#$match[1]))
      # 首项的光标必须处于第 1 列，且整个列表确实能放入当前屏幕。
      (( 10#$match[2] == 1 && hf_first > 0 && hf_first + ${#_hist_fuzzy_shown} - 1 <= LINES )) || hf_first=0
      (( MBEGIN > 1 )) && hf_replay=${hf_input[1,MBEGIN-1]}
      (( MEND < ${#hf_input} )) && hf_replay+=${hf_input[MEND+1,-1]}
      [[ -n $hf_replay ]] && zle -U -- "$hf_replay"
      if [[ $BUFFER != "$hf_saved_buffer" || $POSTDISPLAY != "$hf_saved_post" ]] || (( CURSOR != hf_saved_cursor )); then
        hf_first=0
      fi
      return 0
    fi
  done
  # 等待期间的用户按键/鼠标释放回到 ZLE，不能吞键或填入报告正文。
  [[ -n $hf_input ]] && zle -U -- "$hf_input"
  return 1
}

_hist_fuzzy_mouse() {
  emulate -L zsh
  local hf_fd hf_char hf_packet hf_command
  local -i hf_button hf_x hf_y hf_idx hf_first=0 hf_pressed=$_hist_fuzzy_mouse_pressed
  local -i hf_width=$COLUMNS hf_height=$LINES
  local -a match mbegin mend
  local MATCH
  exec {hf_fd}<>/dev/tty || return 0
  _hist_fuzzy_mouse_pressed=0
  {
    _hist_fuzzy_mouse_packet Mm || return 0
    [[ $hf_packet =~ '^([0-9]{1,3});([0-9]{1,5});([0-9]{1,5})([Mm])$' ]] || return 0
    hf_button=$((10#$match[1])) hf_x=$((10#$match[2])) hf_y=$((10#$match[3]))
    hf_char=$match[4]
    local hf_kind=$hf_char
    _hist_fuzzy_mouse_pressed=0
    (( hf_button == 0 && hf_x >= 1 && hf_x < COLUMNS && hf_y >= 1 && hf_y <= LINES )) || return 0
    (( _hist_fuzzy_mouse_enabled && _hist_fuzzy_active && ! _hist_fuzzy_closed && ${#_hist_fuzzy_shown} )) || return 0
    [[ $BUFFER == "$_hist_fuzzy_query" && -n $_hist_fuzzy_suffix && $POSTDISPLAY == *"$_hist_fuzzy_suffix" ]] || return 0
    (( BUFFERLINES <= LINES )) || return 0
    [[ $(command stty size <&$hf_fd 2>/dev/null) == "$hf_height $hf_width" ]] || return 0
    [[ $hf_kind == M ]] || (( hf_pressed )) || return 0
    _hist_fuzzy_mouse_origin || return 0
    (( hf_first && COLUMNS == hf_width && LINES == hf_height )) || return 0
    [[ $(command stty size <&$hf_fd 2>/dev/null) == "$hf_height $hf_width" ]] || return 0
    hf_idx=$(( hf_y - hf_first + 1 ))
    (( hf_idx >= 1 && hf_idx <= ${#_hist_fuzzy_shown} )) || return 0
    hf_command=$_hist_fuzzy_shown[hf_idx]
    if [[ $hf_kind == M ]]; then
      _hist_fuzzy_mouse_pressed=$hf_idx
      _hist_fuzzy_mouse_buffer=$BUFFER
      _hist_fuzzy_mouse_command=$hf_command
      _hist_fuzzy_mouse_first=$hf_first
      _hist_fuzzy_mouse_size="$hf_height $hf_width"
      _hist_fuzzy_hover=$hf_idx
      _hist_fuzzy_engaged=0
    elif (( hf_idx == hf_pressed && hf_first == _hist_fuzzy_mouse_first )) &&
         [[ $BUFFER == "$_hist_fuzzy_mouse_buffer" && $hf_command == "$_hist_fuzzy_mouse_command" &&
            $_hist_fuzzy_mouse_size == "$hf_height $hf_width" ]]; then
      BUFFER=$hf_command
      CURSOR=${#BUFFER}
      POSTDISPLAY=''
      _hist_fuzzy_dismiss
      _hist_fuzzy_native_key $'\r'
    fi
  } always {
    exec {hf_fd}>&-
  }
  return 0
}

# 只复制键表，不覆盖用户的 main / viins / emacs / vicmd，也不改 Esc。
_hist_fuzzy_make_map() {
  emulate -L zsh
  local base=$1 map=hf-map-$1 entry original key binding
  local -a words
  bindkey -N "$map" "$base"
  for entry in "${(@f)$(bindkey -L -M "$base")}"; do
    words=("${(@Q)${(z)entry}}")
    (( ${words[(Ie)-s]} )) && continue
    original=$words[-1]
    # Esc 保持原始部件，模式切换钩子负责摘掉列表。
    [[ ${words[-2]} == '^[' ]] && continue
    [[ $original == undefined-key ]] && continue
    zle -N "hf-call:$original" _hist_fuzzy_dispatch
    words[-1]=hf-call:$original
    # bindkey -L 对 main 省略 -M，对 vicmd 使用 -a。
    words=("${(@)words:#-a}")
    if (( ${words[(Ie)-M]} )); then words[${words[(Ie)-M]}+1]=$map
    else words=(bindkey -M "$map" "${(@)words[2,-1]}"); fi
    "${words[@]}"
  done
  # vicmd 也用副本消费迟到的终端回报；所有编辑键继续委托原生部件。
  if [[ $base == vicmd ]]; then
    bindkey -M "$map" '\e[<' hist-fuzzy-mouse
    bindkey -M "$map" '\e[?' hist-fuzzy-cursor-report
    _hist_fuzzy_maps[$base]=$map
    return 0
  fi
  for key in $'\e[A' $'\eOA'; do bindkey -M "$map" "$key" hist-fuzzy-up; done
  for key in $'\e[B' $'\eOB'; do bindkey -M "$map" "$key" hist-fuzzy-down; done
  for key in $'\e[C' $'\eOC'; do bindkey -M "$map" "$key" hist-fuzzy-right; done
  bindkey -M "$map" '^I' hist-fuzzy-tab
  bindkey -M "$map" '^M' hist-fuzzy-enter
  bindkey -M "$map" '^J' hist-fuzzy-enter
  bindkey -M "$map" '^G' hist-fuzzy-cancel
  for key in {1..9}; do bindkey -M "$map" "\e$key" hist-fuzzy-pick-$key; done
  bindkey -M "$map" '\e[<' hist-fuzzy-mouse
  bindkey -M "$map" '\e[?' hist-fuzzy-cursor-report
  _hist_fuzzy_maps[$base]=$map
}

_hist_fuzzy_init() {
  _hist_fuzzy_active=1
  _hist_fuzzy_suffix=''
  _hist_fuzzy_retired_suffix=''
  _hist_fuzzy_closed=0
  _hist_fuzzy_engaged=0
  _hist_fuzzy_query=$'\0'
  _hist_fuzzy_shown=()
  _hist_fuzzy_maps=()
  _hist_fuzzy_select
  return 0
}

_hist_fuzzy_select() {
  (( _hist_fuzzy_busy || ! _hist_fuzzy_active )) && return 0
  case $KEYMAP in
    main|emacs|viins)
      _hist_fuzzy_base=$KEYMAP
      [[ -n ${_hist_fuzzy_maps[$KEYMAP]-} ]] || _hist_fuzzy_make_map "$KEYMAP"
      zle -K "${_hist_fuzzy_maps[$KEYMAP]}" ;;
    vicmd)
      _hist_fuzzy_mouse_off
      _hist_fuzzy_detach
      _hist_fuzzy_shown=()
      _hist_fuzzy_engaged=0
      _hist_fuzzy_base=vicmd
      [[ -n ${_hist_fuzzy_maps[vicmd]-} ]] || _hist_fuzzy_make_map vicmd
      zle -K "${_hist_fuzzy_maps[vicmd]}" ;;
    hf-map-*) ;;
    *) _hist_fuzzy_mouse_off; _hist_fuzzy_detach; _hist_fuzzy_shown=(); _hist_fuzzy_engaged=0 ;;
  esac
  return 0
}

_hist_fuzzy_finish() {
  _hist_fuzzy_mouse_off
  _hist_fuzzy_active=0
  _hist_fuzzy_detach
  _hist_fuzzy_shown=()
  [[ $KEYMAP == hf-map-* ]] && zle -K "$_hist_fuzzy_base"
  return 0
}

# autosuggestions 的同步/异步部件都在 highlighter 之后调用 zle -R。
# 在那次刷新之前合成列表，避免先擦掉列表、下一帧才补回的闪烁。
_hist_fuzzy_suggest_highlight() {
  # Esc 的原生 autosuggest 包装器可能恢复进入 vicmd 前保存的 POSTDISPLAY。
  # 清理这份旧后缀；Esc 本身仍保持原绑定。
  if [[ ( $_hist_fuzzy_base == vicmd || ( $KEYMAP != hf-map-* && $KEYMAP != "$_hist_fuzzy_base" ) ) &&
        -n $_hist_fuzzy_retired_suffix && $POSTDISPLAY == *"$_hist_fuzzy_retired_suffix" ]]; then
    POSTDISPLAY=${POSTDISPLAY%"$_hist_fuzzy_retired_suffix"}
  fi
  _hist_fuzzy_original_suggest_highlight "$@"
  if (( _hist_fuzzy_active && _hist_fuzzy_busy != 1 )) && [[ $_hist_fuzzy_base != vicmd && ( $KEYMAP == hf-map-* || $KEYMAP == "$_hist_fuzzy_base" ) ]]; then
    _hist_fuzzy_compose
  fi
  return 0
}

_hist_fuzzy_precmd() {
  _hist_fuzzy_mouse_off
  # SIGINT 跳过 line-finish；ZLE 已把光标放在列表末尾的下一行。
  # 仅在这条退出路径按已知列表行数相对上移并清除，完全不查询绝对光标位置。
  if (( _hist_fuzzy_active && ${#_hist_fuzzy_shown} )) && [[ -n $_hist_fuzzy_suffix ]]; then
    echoti cuu ${#_hist_fuzzy_shown}
    echoti ed
  fi
  _hist_fuzzy_active=0
  _hist_fuzzy_suffix=''
  _hist_fuzzy_shown=()
  _hist_fuzzy_refresh
  if (( ${+functions[_zsh_autosuggest_highlight_apply]} )) &&
     [[ ${functions[_zsh_autosuggest_highlight_apply]} != *'_hist_fuzzy_suggest_highlight'* ]]; then
    functions[_hist_fuzzy_original_suggest_highlight]=$functions[_zsh_autosuggest_highlight_apply]
    functions[_zsh_autosuggest_highlight_apply]='_hist_fuzzy_suggest_highlight "$@"'
  fi
  return 0
}

() {
  local action
  for action in up down right tab enter cancel pick-{1..9}; do
    zle -N hist-fuzzy-$action _hist_fuzzy_key
  done
  zle -N hist-fuzzy-mouse _hist_fuzzy_mouse
  zle -N hist-fuzzy-cursor-report _hist_fuzzy_cursor_report
  add-zle-hook-widget line-init _hist_fuzzy_init
  add-zle-hook-widget line-pre-redraw _hist_fuzzy_draw
  add-zle-hook-widget line-finish _hist_fuzzy_finish
  add-zle-hook-widget keymap-select _hist_fuzzy_select
  zmodload zsh/terminfo
  add-zsh-hook precmd _hist_fuzzy_precmd
  # 私有包装器必须在 autosuggestions 外层，建议插件只包装被委托的原生部件。
  if (( ${+ZSH_AUTOSUGGEST_IGNORE_WIDGETS} )); then
    ZSH_AUTOSUGGEST_IGNORE_WIDGETS+=( 'hf-*' 'hist-fuzzy-*' '_hist_fuzzy_*' )
  fi
}

histf-diag() {
  print -r -- "history_fuzzy v$_HIST_FUZZY_VERSION; zsh $ZSH_VERSION; ${COLUMNS}x${LINES}"
  print -r -- "cached=${#_hist_fuzzy_cache}; max_show=$HIST_FUZZY_MAX_SHOW; renderer=ZLE; mouse=auto"
}
