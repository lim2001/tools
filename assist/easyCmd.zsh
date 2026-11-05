#!/usr/bin/env zsh
# 历史实时下拉：先显示 10 条，选到第 11 条扩展至最多 20 条，再继续滚动。
# ↑/↓ 显示灰字预览，保留用户真实输入和光标；继续打字接着原文字编辑。
# 空输入时首次按方向键打开最近历史；原查询保持到用户编辑为止。
# PageUp/PageDown 逐条调取较旧/较新的原生历史到输入行。
# Tab/→ 默认保留输入行原有补全；先按 ↑/↓ 选择历史项后，Tab/→ 才填该项。
# Alt-1..9 填当前窗口第 N 行；Ctrl-G 收起；主动选择后回车执行该项，
# 未主动选择或已返回输入行编辑时，回车只执行 BUFFER。
# 左键单击填入并保留原菜单；回车执行，或在同一项上双击直接执行一次。
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
# 匹配决定是否入选；全部候选统一按最后使用顺序排列，最近使用的在前。
# 前缀、子串和模糊匹配不分排序优先级，命令长短平权，不统计频次。
# 完整历史缓存后台构建；就绪后原子更新，不改动正在编辑的文字和选中项。

[[ -o interactive && -o zle ]] || return 0
(( ${_EASYCMD_VERSION:-0} >= 28 )) && return 0
typeset -g _EASYCMD_VERSION=28
zmodload zsh/parameter
zmodload zsh/zleparameter
zmodload zsh/zselect
zmodload zsh/datetime
autoload -Uz add-zle-hook-widget add-zsh-hook

# 兼容旧配置变量；新配置统一使用 EASYCMD_*，且新名称优先。
() {
  local name target
  for name in ${(k)parameters[(I)HIST_FUZZY_*]}; do
    target=EASYCMD_${name#HIST_FUZZY_}
    (( ${+parameters[$target]} )) && continue
    if [[ ${(tP)name} == *array* ]]; then
      typeset -ga "$target"
      set -A "$target" "${(@P)name}"
    else
      typeset -g "$target=${(P)name}"
    fi
  done
}

# 仅用于从旧名称热升级：移除旧钩子和私有键表，保留用户原生绑定及配置。
if (( ${_HIST_FUZZY_VERSION:-0} > 0 )); then
  if (( _HIST_FUZZY_VERSION < 13 )); then
    print -u2 -- 'easyCmd: 请新开 zsh，以清除早期实验版覆盖的部件。'
    unset _EASYCMD_VERSION
    return 1
  fi
  () {
    local name target
    local -a names
    (( _HIST_FUZZY_VERSION < 20 )) && [[ $EASYCMD_COLOR_HOVER == bg=cyan,fg=black ]] &&
      EASYCMD_COLOR_HOVER=bg=23,fg=255
    (( _HIST_FUZZY_VERSION < 23 && ${EASYCMD_MAX_SHOW:-10} == 10 )) && EASYCMD_MAX_SHOW=20
    add-zle-hook-widget -d line-init _hist_fuzzy_init
    add-zle-hook-widget -d line-pre-redraw _hist_fuzzy_draw
    add-zle-hook-widget -d line-finish _hist_fuzzy_finish
    add-zle-hook-widget -d keymap-select _hist_fuzzy_select
    add-zsh-hook -d precmd _hist_fuzzy_precmd
    if [[ ${functions[_zsh_autosuggest_highlight_apply]-} == *'_hist_fuzzy_suggest_highlight'* ]] &&
        (( ${+functions[_hist_fuzzy_original_suggest_highlight]} )); then
      functions[_zsh_autosuggest_highlight_apply]=$functions[_hist_fuzzy_original_suggest_highlight]
    fi
    (( ${+functions[_hist_fuzzy_mouse_off]} )) && _hist_fuzzy_mouse_off
    names=("${(@f)$(bindkey -l)}")
    names=("${(@M)names:#hf-map-*}")
    (( ${#names} )) && bindkey -D "${names[@]}"
    names=( ${(k)widgets[(I)hf-call:*]} ${(k)widgets[(I)hist-fuzzy-*]} ${(k)widgets[(I)_hist_fuzzy*]} )
    (( ${#names} )) && zle -D "${names[@]}"
    ZSH_AUTOSUGGEST_IGNORE_WIDGETS=("${(@)ZSH_AUTOSUGGEST_IGNORE_WIDGETS:#hf-\*}")
    ZSH_AUTOSUGGEST_IGNORE_WIDGETS=("${(@)ZSH_AUTOSUGGEST_IGNORE_WIDGETS:#hist-fuzzy-\*}")
    ZSH_AUTOSUGGEST_IGNORE_WIDGETS=("${(@)ZSH_AUTOSUGGEST_IGNORE_WIDGETS:#_hist_fuzzy_\*}")
    names=( ${(k)functions[(I)_hist_fuzzy*]} )
    (( ${#names} )) && unfunction "${names[@]}"
    (( ${+functions[histf-diag]} )) && unfunction histf-diag
    names=( ${(k)parameters[(I)_hist_fuzzy*]} ${(k)parameters[(I)HIST_FUZZY_*]} )
    (( ${#names} )) && unset "${names[@]}"
    unset _HIST_FUZZY_VERSION
  }
fi

: ${EASYCMD_MAX_HIST:=10000}
: ${EASYCMD_MAX_SHOW:=20}
: ${EASYCMD_MIN_LEN:=1}
: ${EASYCMD_COLOR_MATCH:=fg=green,bold}
# 256 色深青底 #005f5f、浅色字 #eeeeee、浅绿匹配字 #afffaf。
# 选中行两种文字的对比度分别为 6.46:1 / 6.33:1，避免绿字叠亮青底。
: ${EASYCMD_COLOR_HOVER:=bg=23,fg=255}
: ${EASYCMD_COLOR_HOVER_MATCH:=fg=157,bold}
: ${EASYCMD_COLOR_PREVIEW:=${ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE:-fg=8}}
# 同项、同位置附近的两次左键点击间隔；0 禁用双击执行。
: ${EASYCMD_DOUBLE_CLICK_MS:=400}
: ${EASYCMD_FUZZY_MAX:=4}
: ${EASYCMD_FUZZY_MIN_LEN:=2}
: ${EASYCMD_SPAN_SLACK:=3}
# 限制紧凑子序列的逐字符检查数量，避免宽松匹配带来过多开销。
: ${EASYCMD_LOOSE_LIMIT:=40}
: ${EASYCMD_BASE_SCORE:=100000}
typeset -ga EASYCMD_IGNORE
(( ${#EASYCMD_IGNORE} )) || EASYCMD_IGNORE=(shl shh auto_history history_20)
typeset -ga _easyCmd_cache=() _easyCmd_result=() _easyCmd_hits=()
typeset -ga _easyCmd_qpat=() _easyCmd_qchr=() _easyCmd_toks=()
typeset -g _easyCmd_cand='' _easyCmd_first=0 _easyCmd_span=0
typeset -g _easyCmd_sc=0 _easyCmd_wn=0 _easyCmd_wv=0
typeset -gi _easyCmd_async_available=0 _easyCmd_refresh_generation=0
typeset -gi _easyCmd_refresh_started=0 _easyCmd_cache_revision=0 _easyCmd_query_revision=-1
typeset -g _easyCmd_refresh_fd='' _easyCmd_refresh_buffer=''
zmodload zsh/system 2>/dev/null && _easyCmd_async_available=1

# zsh 自己读取 HISTFILE；这里只取内存历史，保持命令的引号和空白原样。
# 不拆多行命令，避免把其中一行误当成独立可执行的历史项。
_easyCmd_refresh() {
  emulate -L zsh
  setopt extendedglob
  local event cmd first
  local -a events=("${(@Onk)history}")
  local -A seen=()
  _easyCmd_cache=()
  for event in "${(@)events[1,EASYCMD_MAX_HIST]}"; do
    cmd=$history[$event]
    [[ -z ${cmd//[[:space:]]/} || $cmd == *[[:cntrl:]]* ]] && continue
    first=${${cmd##[[:space:]]#}%% *}
    (( ${EASYCMD_IGNORE[(Ie)$first]} )) && continue
    [[ -n ${seen[$cmd]-} ]] && continue
    seen[$cmd]=1
    _easyCmd_cache+=("$cmd")
  done
  _easyCmd_query=$'\0'
  return 0
}

# 历史只在子进程的内存快照中整理；不执行历史文本、不写临时历史文件。
# 同时最多一个任务。期间的新请求合并，旧快照不会覆盖较新的请求。
_easyCmd_refresh_close() {
  emulate -L zsh
  if [[ -n $_easyCmd_refresh_fd ]]; then
    zle -F "$_easyCmd_refresh_fd" 2>/dev/null
    { exec {_easyCmd_refresh_fd}<&- } 2>/dev/null
  fi
  _easyCmd_refresh_fd=''
  _easyCmd_refresh_buffer=''
  return 0
}

_easyCmd_refresh_start() {
  emulate -L zsh
  _easyCmd_refresh_started=$_easyCmd_refresh_generation
  _easyCmd_refresh_buffer=''
  if ! exec {_easyCmd_refresh_fd}< <(
    _easyCmd_refresh || exit 1
    (( ${#_easyCmd_cache} )) && print -rl -- "${_easyCmd_cache[@]}"
    # 过滤后的历史不含控制字符；NUL 仅作为整份结果完成的标记。
    print -rn -- $'\0'
  ); then
    _easyCmd_refresh_fd=''
    return 1
  fi
  zle -F "$_easyCmd_refresh_fd" _easyCmd_refresh_ready || {
    _easyCmd_refresh_close
    return 1
  }
}

_easyCmd_refresh_request() {
  emulate -L zsh
  (( ++_easyCmd_refresh_generation ))
  [[ -n $_easyCmd_refresh_fd ]] && return 0
  if (( _easyCmd_async_available )) && _easyCmd_refresh_start; then
    return 0
  fi
  # 缺少异步模块或描述符不足时仍可用，回退到原有的同步行为。
  _easyCmd_refresh
  (( ++_easyCmd_cache_revision ))
  return 0
}

_easyCmd_refresh_ready() {
  emulate -L zsh
  local fd=$1 chunk payload
  local -i rc attempt complete=0 started=$_easyCmd_refresh_started
  [[ $fd == "$_easyCmd_refresh_fd" ]] || return 0
  if [[ -n $2 && $2 != hup ]]; then
    _easyCmd_refresh_close
    (( started != _easyCmd_refresh_generation )) && _easyCmd_refresh_start
    return 0
  fi
  # 只读取已经到达的数据；限制单次处理量，绝不等待子进程输出。
  for attempt in {1..4}; do
    chunk=''
    sysread -i "$fd" -s 65536 -t 0 chunk
    rc=$?
    if (( rc == 0 )); then
      _easyCmd_refresh_buffer+=$chunk
      if [[ $_easyCmd_refresh_buffer == *$'\0' ]]; then
        complete=1
        break
      fi
    elif (( rc == 4 )); then
      return 0
    else
      # EOF/错误但没有完成标记：保留上一份完整缓存。
      _easyCmd_refresh_close
      (( started != _easyCmd_refresh_generation )) && _easyCmd_refresh_start
      return 0
    fi
  done
  (( complete )) || return 0
  payload=${_easyCmd_refresh_buffer%$'\0'}
  _easyCmd_refresh_close
  if (( started != _easyCmd_refresh_generation )); then
    _easyCmd_refresh_start
    return 0
  fi
  payload=${payload%$'\n'}
  if [[ -n $payload ]]; then
    _easyCmd_cache=("${(@f)payload}")
  else
    _easyCmd_cache=()
  fi
  (( ++_easyCmd_cache_revision ))
  # 用户选中的列表保持原样，直到改写查询或进入下一行。
  zle easyCmd-cache-ready 2>/dev/null
  return 0
}

_easyCmd_refresh_redraw() {
  (( _easyCmd_active && ! _easyCmd_busy && ! _easyCmd_engaged &&
     ! _easyCmd_pinned && ! _easyCmd_preview )) || return 0
  [[ $_easyCmd_base != vicmd && $KEYMAP == easyCmd-map-* ]] || return 0
  _easyCmd_compose
  zle -R
  return 0
}
# 维度注册：$1=维度名  $2=默认权重
typeset -ga _easyCmd_dims                    # 维度名列表（顺序无关）
typeset -gA _easyCmd_dim_wv                  # 维度名 -> 权重变量名
typeset -gA _easyCmd_dim_code                # 维度名 -> 打分代码片段
_easyCmd_dims=()
_easyCmd_dim_wv=()
_easyCmd_dim_code=()
typeset -g  _easyCmd_dim_val=0               # 维度函数的输出

# 注册一个维度：
#   $1=维度名  $2=默认权重  $3=打分代码片段（推荐，编译后零函数调用开销）
# 不传 $3 时退化为「调用 _easyCmd_dim_<名> 函数」的写法（方便，但每候选多一次调用）
#
# ⚠ 片段里的局部变量请统一加「维度名_」前缀！
#   所有维度的片段会被编译进同一个函数，而 zsh 对 functions[name]="..." 定义的
#   函数里「同一个变量名被 local 两次」会把旧值打印到 stdout（这是血泪教训：
#   屏幕上一堆 k=3 / sc=502823 就是这么来的）。用前缀隔开就不会撞名。
_easyCmd_dim_add() {
  local name=$1 w=$2 code=$3 var=EASYCMD_W_${1:u}
  (( ${_easyCmd_dims[(I)$name]} )) || _easyCmd_dims+=($name)
  _easyCmd_dim_wv[$name]=$var
  (( ${(P)+var} )) || typeset -g $var=$w             # 未定义时才设默认值
  [[ -n $code ]] && _easyCmd_dim_code[$name]=$code
  _easyCmd_dim_compile
  return 0
}

# 把所有维度的片段拼成一个函数，打分时只需要一次函数调用。
# 用 functions[...]= 而不是 eval：这样片段里的 $变量 不会被二次展开。
_easyCmd_dim_compile() {
  local d body='' nl=$'\n'
  for d in $_easyCmd_dims; do
    if [[ -n ${_easyCmd_dim_code[$d]} ]]; then
      body+="    _easyCmd_dim_val=0${nl}${_easyCmd_dim_code[$d]}${nl}"
      body+="    (( sc += _easyCmd_dim_val * \$EASYCMD_W_${d:u} ))${nl}"
    else
      body+="    _easyCmd_dim_val=0${nl}"
      body+="    _easyCmd_dim_${d} 2>/dev/null && (( sc += _easyCmd_dim_val * \$EASYCMD_W_${d:u} ))${nl}"
    fi
  done
  functions[_easyCmd_score_impl]="
  local sc=\$EASYCMD_BASE_SCORE
$body  _easyCmd_sc=\$sc
  return 0
"
}

# ---- 内置维度（正分 = 加分项）----
# 以「代码片段」注册，编译时被拼进 _easyCmd_score_impl，没有函数调用开销。
# 片段里可直接用 $_easyCmd_hits / $_easyCmd_cand / $_easyCmd_toks 等变量。

# 相邻命中：连续段越长说明查询串越完整
_easyCmd_dim_add consec 2000 '
  local consec_k consec_v=0
  for (( consec_k = 2; consec_k <= ${#_easyCmd_hits}; consec_k++ )); do
    (( _easyCmd_hits[consec_k] == _easyCmd_hits[consec_k-1] + 1 )) && (( consec_v += 1 ))
  done
  _easyCmd_dim_val=$consec_v'

# 命中字符落在单词边界（分隔符之后）或行首：语义相关性更强
_easyCmd_dim_add bound 1000 '
  local bound_k bound_v=0 bound_pc
  for bound_k in $_easyCmd_hits; do
    if (( bound_k == 1 )); then
      (( bound_v += 2 ))                             # 行首加倍
    else
      bound_pc=${_easyCmd_cand[bound_k-1]}
      [[ -z $bound_pc || $bound_pc != [[:alnum:]_.] ]] && (( bound_v += 1 ))
    fi
  done
  _easyCmd_dim_val=$bound_v'

# 查询里的「空格」命中了候选里的空格 —— 说明两边分词结构对齐
_easyCmd_dim_add space 1500 '
  local space_k space_v=0
  for (( space_k = 1; space_k <= ${#_easyCmd_qchr}; space_k++ )); do
    [[ $_easyCmd_qchr[space_k] == " " ]] && (( space_v += 1 ))
  done
  _easyCmd_dim_val=$space_v'

# 查询里的标点命中了候选里的标点 —— 路径 / 选项结构对齐
_easyCmd_dim_add punct 800 '
  local punct_k punct_v=0 punct_c
  for (( punct_k = 1; punct_k <= ${#_easyCmd_qchr}; punct_k++ )); do
    punct_c=$_easyCmd_qchr[punct_k]
    [[ $punct_c != [[:alnum:]] && $punct_c != " " ]] && (( punct_v += 1 ))
  done
  _easyCmd_dim_val=$punct_v'

# ---- 词级缩写匹配（b k -> build kernel，d mes -> dmesg）----
# 查询词按顺序去「消耗」候选的单词：每个查询词必须是某个单词开头（或某个单词
# 被前一个查询词吃掉一部分后剩余部分）的前缀；允许一个单词被多个查询词连续吃。
# 输出：_easyCmd_wn = 命中的查询词数
#       _easyCmd_wv = 2*命中数 - 中途跳过的单词数（跳词越多说明匹配越散乱）
typeset -g  _easyCmd_wm_cand=$'\0'             # 单词拆分缓存：同一个候选只算一次
_easyCmd_words_match() {
  local cand=$1
  local -a cw
  # 打分时要算一次、分级判定又要算一次 → 结果缓存起来（两者总是同一候选连续调用）
  [[ $cand == $_easyCmd_wm_cand ]] && return 0
  _easyCmd_wm_cand=$cand
  cw=(${=cand//[^[:alnum:]]/ })                   # "./build.sh kernel" -> build sh kernel
  local wi=1 rem='' t
  local -i found hits=0 skip=0
  for t in $_easyCmd_toks; do
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
  _easyCmd_wn=$hits
  _easyCmd_wv=$(( hits * 2 - skip ))
}

# 缩写：命中了几个查询词（带散乱惩罚）
_easyCmd_dim_add abbrev 4000 '
  if (( ${#_easyCmd_toks} > 1 )); then
    _easyCmd_words_match $_easyCmd_cand
    _easyCmd_dim_val=$_easyCmd_wv
  fi'

# ---- 内置维度（负分 = 惩罚项）----
_easyCmd_dim_add span 50 '_easyCmd_dim_val=$(( - $_easyCmd_span ))'
_easyCmd_dim_add pos  20 '_easyCmd_dim_val=$(( - $_easyCmd_first ))'

# 候选是否为查询的完整缩写（所有查询词都被消耗掉）→ 供分级使用
_easyCmd_is_abbrev() {
  (( ${#_easyCmd_toks} > 1 )) || return 1
  _easyCmd_words_match $1
  (( _easyCmd_wn == ${#_easyCmd_toks} ))
}

# 打分主体：一次字符扫描 + 遍历维度
# 输出：全局 _easyCmd_sc（分数，越大越好）/ _easyCmd_span
#       返回 0 = 命中所有查询字符，1 = 不是子序列
_easyCmd_score() {
  local cand=$1
  local -a qp qc hits=()
  qp=($_easyCmd_qpat)                             # 查询字符（已转义成 pattern）
  qc=($_easyCmd_qchr)                             # 查询字符（原样）
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

  _easyCmd_cand=$cand
  _easyCmd_hits=($hits)
  _easyCmd_first=$first
  _easyCmd_span=$(( last - first + 1 ))

  # 紧凑子序列筛选只需要命中位置和跨度，不计算排序已不再使用的分数。
  [[ $2 == span-only ]] || _easyCmd_score_impl
  return 0
}


# 缓存已经按最后使用顺序去重；匹配只负责筛选，直接保留这个顺序。
_easyCmd_build() {
  emulate -L zsh
  setopt extendedglob
  local q=$1 cand pat text
  local -i loose_checked=0 loose_count=0
  _easyCmd_result=()
  _easyCmd_qchr=() _easyCmd_qpat=() _easyCmd_toks=() _easyCmd_hits=()
  q=${${q##[[:space:]]#}%%[[:space:]]#}
  # 空输入由方向键显式打开最近历史；沿用缓存的去重和过滤，保持时间顺序。
  if [[ -z $q ]]; then
    if (( _easyCmd_recent && EASYCMD_MAX_SHOW > 0 && ${#_easyCmd_cache} )); then
      _easyCmd_result=("${_easyCmd_cache[@]}")
    fi
    return 0
  fi
  (( ${#q} >= EASYCMD_MIN_LEN && EASYCMD_MAX_SHOW > 0 )) || return 0
  [[ $q == *[[:cntrl:]]* ]] && return 0
  _easyCmd_qchr=("${(@s::)q}")
  for text in "${_easyCmd_qchr[@]}"; do _easyCmd_qpat+=("${(b)text}"); done
  _easyCmd_toks=(${=q})
  _easyCmd_wm_cand=$'\0'
  pat="*${(j:*:)_easyCmd_qpat}*"
  # 内置数组匹配在 C 层筛选，避免对每条历史执行 shell 分支。
  # 连续子串也是子序列；预筛选不会漏掉原有的精确或模糊结果。
  # 连续匹配必须先判断；长输入含大量重复字符时可避免子序列模式回溯。
  local filter="(*${(b)q}*|${pat})"
  local -a candidates=("${(@M)_easyCmd_cache:#${~filter}}")
  if (( ${#_easyCmd_toks} > 1 || ${#q} == 1 )); then
    _easyCmd_result=("${candidates[@]}")
    return 0
  fi
  for cand in "${candidates[@]}"; do
    if [[ $cand == *"$q"* ]]; then
      _easyCmd_result+=("$cand")
    elif [[ $cand == ${~pat} ]]; then
      if (( ${#_easyCmd_toks} > 1 )); then
        # 保留原有缩写、多词子序列匹配，不再按类别或得分重排。
        _easyCmd_result+=("$cand")
      elif (( ${#q} >= EASYCMD_FUZZY_MIN_LEN &&
              loose_count < EASYCMD_FUZZY_MAX && ++loose_checked <= EASYCMD_LOOSE_LIMIT )); then
        # 单词的松散子序列仍需足够紧凑；预算只限制这一类的检查和数量。
        _easyCmd_score "$cand" span-only || continue
        (( _easyCmd_span <= ${#q} + EASYCMD_SPAN_SLACK )) || continue
        _easyCmd_result+=("$cand")
        (( ++loose_count ))
      fi
    fi
  done
  return 0
}

typeset -g _easyCmd_suffix='' _easyCmd_query=$'\0' _easyCmd_base=main
typeset -g _easyCmd_retired_suffix=''
typeset -g _easyCmd_preview=0 _easyCmd_preview_suffix='' _easyCmd_retired_preview=''
typeset -g _easyCmd_saved_suggestion=''
typeset -g _easyCmd_mouse_enabled=0 _easyCmd_mouse_pressed=0
typeset -g _easyCmd_mouse_buffer='' _easyCmd_mouse_command=''
typeset -g _easyCmd_mouse_first=0 _easyCmd_mouse_size=''
typeset -gF _easyCmd_mouse_press_time=0 _easyCmd_click_time=0
typeset -gi _easyCmd_mouse_double=0 _easyCmd_click_index=0 _easyCmd_click_x=0 _easyCmd_click_y=0
typeset -g _easyCmd_click_command='' _easyCmd_click_size=''
typeset -g _easyCmd_pinned=0 _easyCmd_pinned_buffer=''
typeset -g _easyCmd_recent=0
typeset -g _easyCmd_suppressed='' _easyCmd_closed=0 _easyCmd_hover=1
typeset -g _easyCmd_top=1 _easyCmd_expanded=0
typeset -g _easyCmd_engaged=0 _easyCmd_selection_cursor=0
typeset -g _easyCmd_busy=0 _easyCmd_active=0
typeset -ga _easyCmd_shown=()
typeset -ga _easyCmd_highlights=()
typeset -gA _easyCmd_maps=()

# 只摘掉自己的后缀和高亮；autosuggestions 异步替换 POSTDISPLAY 时不回写旧建议。
_easyCmd_detach() {
  local entry
  local -i preview_drawn=0
  local -a keep=()
  local -A owned=()
  if [[ -n $_easyCmd_suffix && $POSTDISPLAY == *"$_easyCmd_suffix" ]]; then
    POSTDISPLAY=${POSTDISPLAY%"$_easyCmd_suffix"}
    (( _easyCmd_preview )) && preview_drawn=1
  fi
  if { (( preview_drawn )) || [[ -n $_easyCmd_preview_suffix ]]; } &&
      [[ $POSTDISPLAY == "$_easyCmd_preview_suffix" ]]; then
    POSTDISPLAY=''
    # 委托原生编辑/收起时恢复原来的建议；候选灰字绝不交给原生接受部件。
    [[ $BUFFER == "$_easyCmd_pinned_buffer" ]] && POSTDISPLAY=$_easyCmd_saved_suggestion
  fi
  [[ -n $_easyCmd_preview_suffix ]] && _easyCmd_retired_preview=$_easyCmd_preview_suffix
  _easyCmd_preview_suffix=''
  [[ -n $_easyCmd_suffix ]] && _easyCmd_retired_suffix=$_easyCmd_suffix
  _easyCmd_suffix=''
  for entry in "${_easyCmd_highlights[@]}"; do owned[$entry]=1; done
  for entry in "${region_highlight[@]}"; do
    [[ -n ${owned[$entry]-} ]] || keep+=("$entry")
  done
  region_highlight=("${keep[@]}")
  _easyCmd_highlights=()
  return 0
}

# 前缀匹配只预览未输入部分；模糊匹配另显完整候选，不改写真实文字。
# 调用方用局部 REPLY 接收，供屏幕高度计算与实际绘制使用同一段文本。
_easyCmd_preview_text() {
  local command=$_easyCmd_result[_easyCmd_hover]
  if [[ $command == "$BUFFER"* ]]; then
    REPLY=${command#"$BUFFER"}
  else
    REPLY="  → $command"
  fi
}

_easyCmd_update() {
  emulate -L zsh
  # 调整窗口大小后，前一次点击不能再组成双击。
  if (( _easyCmd_click_time )) && [[ $_easyCmd_click_size != "$LINES $COLUMNS" ]]; then
    _easyCmd_mouse_reset
  fi
  # 翻页键调取历史时，建议插件的中间重绘也保持列表收起。
  (( ${_easyCmd_history_browsing:-0} )) && { _easyCmd_shown=(); return 0; }
  # 预览及鼠标填入都保留原查询；真实文字变化后重新搜索。
  if [[ $BUFFER != "$_easyCmd_pinned_buffer" ]]; then
    _easyCmd_pinned=0
    _easyCmd_preview=0
  fi
  if (( _easyCmd_recent && ! _easyCmd_pinned )) && [[ -n $BUFFER ]]; then
    _easyCmd_recent=0
    _easyCmd_query=$'\0'
  fi
  if (( _easyCmd_closed )); then
    [[ $BUFFER == "$_easyCmd_suppressed" ]] && { _easyCmd_shown=(); return 0; }
    _easyCmd_closed=0
  fi
  if (( ! _easyCmd_pinned )) && { [[ $BUFFER != "$_easyCmd_query" ]] ||
      (( ! _easyCmd_engaged && ! _easyCmd_preview && _easyCmd_query_revision != _easyCmd_cache_revision )); }; then
    _easyCmd_query=$BUFFER
    _easyCmd_query_revision=$_easyCmd_cache_revision
    _easyCmd_build "$BUFFER"
    _easyCmd_hover=1
    _easyCmd_top=1
    _easyCmd_expanded=0
    _easyCmd_engaged=0
  fi
  # 光标回到输入行编辑后，Tab/→ 恢复原生含义；探针/重绘不改变选择。
  (( CURSOR != _easyCmd_selection_cursor )) && _easyCmd_engaged=0
  if (( ! ${#_easyCmd_result} )); then _easyCmd_shown=(); return 0; fi
  local part REPLY display="$BUFFER$POSTDISPLAY"
  if (( _easyCmd_preview )); then
    _easyCmd_preview_text
    display="$BUFFER$REPLY"
  fi
  local -i n=$(( LINES - 3 )) limit=10
  (( _easyCmd_hover > 10 )) && _easyCmd_expanded=1
  (( _easyCmd_expanded )) && limit=20
  for part in "${(@f)display}"; do
    (( n -= ${(m)#part} / (COLUMNS > 0 ? COLUMNS : 80) + 1 ))
  done
  (( n > EASYCMD_MAX_SHOW )) && n=$EASYCMD_MAX_SHOW
  (( n > limit )) && n=$limit
  (( n > ${#_easyCmd_result} )) && n=${#_easyCmd_result}
  if (( n < 1 || COLUMNS < 8 )); then _easyCmd_shown=(); return 0; fi
  (( _easyCmd_hover > ${#_easyCmd_result} )) && _easyCmd_hover=${#_easyCmd_result}
  (( _easyCmd_hover < 1 )) && _easyCmd_hover=1
  (( _easyCmd_top > ${#_easyCmd_result} - n + 1 )) && _easyCmd_top=$(( ${#_easyCmd_result} - n + 1 ))
  (( _easyCmd_top < 1 )) && _easyCmd_top=1
  (( _easyCmd_hover < _easyCmd_top )) && _easyCmd_top=$_easyCmd_hover
  (( _easyCmd_hover >= _easyCmd_top + n )) && _easyCmd_top=$(( _easyCmd_hover - n + 1 ))
  _easyCmd_shown=("${(@)_easyCmd_result[_easyCmd_top,_easyCmd_top+n-1]}")
  return 0
}

_easyCmd_draw() {
  (( _easyCmd_busy || ! _easyCmd_active )) && return 0
  [[ $KEYMAP == easyCmd-map-* && $_easyCmd_base != vicmd ]] || return 0
  _easyCmd_compose
}

_easyCmd_compose() {
  emulate -L zsh
  _easyCmd_detach
  (( PENDING || KEYS_QUEUED_COUNT )) && [[ $1 != mouse ]] && return 0
  _easyCmd_update
  (( ${#_easyCmd_shown} )) || { _easyCmd_mouse_off; return 0; }
  local line row colour number REPLY
  # 旧版 ZLE 遇到重复 fg 会停止解析；先移除选中行前景，再设置匹配字颜色。
  local -a hover_match_base=("${(@s:,:)EASYCMD_COLOR_HOVER}")
  [[ ,$EASYCMD_COLOR_HOVER_MATCH, == *,fg=*,* ]] &&
    hover_match_base=("${(@)hover_match_base:#fg=*}")
  local hover_match="${(j:,:)hover_match_base},$EASYCMD_COLOR_HOVER_MATCH"
  local -i i=0 index off pos limit=$(( COLUMNS - 1 )) start=${#region_highlight} run end digits prefix
  if (( _easyCmd_preview )); then
    # 只使用 POSTDISPLAY 绘制灰字；在委托原生部件前会摘除，绝不被当成输入。
    _easyCmd_preview_text
    _easyCmd_preview_suffix=$REPLY
    POSTDISPLAY=$_easyCmd_preview_suffix
    region_highlight+=("${#BUFFER} $(( ${#BUFFER} + ${#POSTDISPLAY} )) $EASYCMD_COLOR_PREVIEW, memo=easyCmd")
  fi
  number=$(( _easyCmd_top + ${#_easyCmd_shown} - 1 ))
  digits=${#number}
  (( digits < 2 )) && digits=2
  prefix=$(( digits + 1 ))
  # 保留输入和建议的折行空间；很小的终端直接少画几条。
  (( limit >= 8 )) || return 0
  for line in "${_easyCmd_shown[@]}"; do
    (( ++i ))
    index=$(( _easyCmd_top + i - 1 ))
    # (m) 按屏幕单元格裁剪和填充；不展开历史中的 %、$() 等文本。
    if (( ${(m)#line} > limit - prefix )); then
      line="${(mr:$((limit - prefix - 1)):)line}…"
    fi
    row="${(l:digits::0:)index} $line"
    row=${(mr:limit:)row}
    off=$(( ${#BUFFER} + ${#POSTDISPLAY} + ${#_easyCmd_suffix} + 1 ))
    _easyCmd_suffix+=$'\n'$row
    colour=fg=default,bg=default
    (( index == _easyCmd_hover )) && colour=$EASYCMD_COLOR_HOVER
    # 5.8 会把 memo 当成最后一个样式值的一部分；逗号先结束该值。
    region_highlight+=("$off $((off + ${#row})) $colour, memo=easyCmd")
    _easyCmd_hits=()
    (( ${#_easyCmd_qchr} )) && _easyCmd_score "$_easyCmd_shown[i]"
    colour=$EASYCMD_COLOR_MATCH
    (( index == _easyCmd_hover )) && colour=$hover_match
    run=0 end=0
    for pos in "${_easyCmd_hits[@]}" 0; do
      if (( pos != end + 1 || pos > ${#line} )); then
        (( run )) && region_highlight+=("$((off + prefix - 1 + run)) $((off + prefix + end)) $colour, memo=easyCmd")
        run=0
      fi
      (( !pos || pos > ${#line} )) && break
      (( run )) || run=$pos
      end=$pos
    done
  done
  POSTDISPLAY+=$_easyCmd_suffix
  _easyCmd_highlights=("${(@)region_highlight[start+1,-1]}")
  _easyCmd_mouse_on
  return 0
}

_easyCmd_dismiss() {
  _easyCmd_preview=0
  _easyCmd_expanded=0
  _easyCmd_pinned=0
  _easyCmd_recent=0
  _easyCmd_mouse_off
  _easyCmd_detach
  _easyCmd_closed=1
  _easyCmd_suppressed=$BUFFER
  _easyCmd_engaged=0
  _easyCmd_shown=()
  return 0
}

# 私有键表中的所有部件先摘列表，再委托原来的部件（包括 Ctrl-F 等建议接受键）。
# zle -w 保留原生 WIDGET 名；执行期间还原 KEYMAP，兼容 vi-mode 的模式判断。
_easyCmd_dispatch() {
  _easyCmd_call "${WIDGET#easyCmd-call:}" "$@"
}

_easyCmd_call() {
  _easyCmd_mouse_reset
  local original=$1 ret=0 ec_before_buffer=$BUFFER ec_before_cursor=$CURSOR
  shift
  local -i completion=0
  _easyCmd_detach
  # 清空/删除在空 BUFFER 上也应退出预览，不能随后回车执行被清掉的灰字。
  if (( _easyCmd_preview )) && [[ $original == *self-insert* || $original == *delete* ||
      $original == *kill* || $original == *paste* ]]; then
    _easyCmd_preview=0
    _easyCmd_pinned=0
    _easyCmd_recent=0
    _easyCmd_engaged=0
    _easyCmd_query=$'\0'
  fi
  [[ $original == *complete* || $original == *expand* || $original == *list-choices* ||
     ${widgets[$original]-} == completion:* ]] && completion=1
  (( completion )) && _easyCmd_dismiss
  _easyCmd_busy=1
  zle -K "$_easyCmd_base"
  {
    _easyCmd_busy=2
    zle "$original" -w -- "$@"
    ret=$?
  } always {
    _easyCmd_busy=1
    # 连续输入可能跳过中间帧；即使后续退格把文字恢复原样，编辑也应退出列表选择。
    if [[ $BUFFER != "$ec_before_buffer" ]] || (( CURSOR != ec_before_cursor )); then
      _easyCmd_engaged=0
      _easyCmd_preview=0
    fi
    if [[ $BUFFER != "$ec_before_buffer" ]]; then
      _easyCmd_pinned=0
      _easyCmd_preview=0
      if (( _easyCmd_recent )); then
        _easyCmd_recent=0
        _easyCmd_query=$'\0'
      fi
    fi
    if (( completion )); then _easyCmd_suppressed=$BUFFER; fi
    if [[ $KEYMAP == "$_easyCmd_base" ]] && (( _easyCmd_active )); then
      zle -K "${_easyCmd_maps[$_easyCmd_base]}"
    fi
    _easyCmd_busy=0
    _easyCmd_select
  }
  return $ret
}

_easyCmd_key() {
  _easyCmd_mouse_reset
  emulate -L zsh
  local action=${WIDGET#easyCmd-}
  local -i idx opening=0
  _easyCmd_detach
  if [[ $action == up || $action == down ]]; then
    if (( _easyCmd_closed )) || { [[ -z $BUFFER ]] && (( ! _easyCmd_recent && ! _easyCmd_pinned )); }; then
      [[ -z $BUFFER ]] && _easyCmd_recent=1
      _easyCmd_closed=0
      _easyCmd_query=$'\0'
      opening=1
    fi
  fi
  _easyCmd_update
  # 默认青色行只是预览；主动选择后 Tab/→ 填入，Enter 填入并执行。
  if (( ${#_easyCmd_shown} )) &&
     { [[ $action != tab && $action != right && $action != enter ]] || (( _easyCmd_engaged )); }; then
    case $action in
      up|down)
        if (( ! opening )); then
          if [[ $action == up ]]; then
            (( _easyCmd_hover > 1 )) && (( --_easyCmd_hover ))
          else
            (( _easyCmd_hover < ${#_easyCmd_result} )) && (( ++_easyCmd_hover ))
          fi
        fi
        # 方向键只改选择；真实文字及编辑位置始终保留，灰字由 POSTDISPLAY 绘制。
        (( _easyCmd_preview )) || _easyCmd_saved_suggestion=$POSTDISPLAY
        _easyCmd_preview=1
        _easyCmd_pinned=1
        _easyCmd_pinned_buffer=$BUFFER
        _easyCmd_engaged=1
        _easyCmd_selection_cursor=$CURSOR ;;
      cancel) _easyCmd_dismiss ;;
      tab|right|enter|pick-*)
        idx=$_easyCmd_hover
        [[ $action == pick-* ]] && idx=$(( _easyCmd_top + ${action#pick-} - 1 ))
        if (( idx >= _easyCmd_top && idx < _easyCmd_top + ${#_easyCmd_shown} )); then
          BUFFER=$_easyCmd_result[idx]
          CURSOR=${#BUFFER}
          POSTDISPLAY=''
          _easyCmd_dismiss
        fi ;;
    esac
    # 回车继续调用原来的绑定；填入、收起已完成，原生接受部件只执行一次。
    [[ $action == enter ]] || return 0
  fi
  # 无匹配、无历史、窗口太小等情况也不回退到原生历史导航。
  [[ $action == up || $action == down ]] && return 0
  # 未主动选择（即使有列表）也按当前原生绑定执行，包括用户自定义的灰字接受键。
  _easyCmd_native_key "$KEYS" "$@"
}

# 单独的翻页键路径：调用原生历史部件（含插件包装），不触发模糊列表。
_easyCmd_history_key() {
  local -i _easyCmd_history_browsing=1
  local original=up-history
  [[ $WIDGET == *-down ]] && original=down-history
  _easyCmd_dismiss
  {
    _easyCmd_call "$original" "$@"
  } always {
    _easyCmd_suppressed=$BUFFER
  }
}

_easyCmd_native_key() {
  local key=$1 binding original
  local -a words
  shift
  binding=$(bindkey -L -M "$_easyCmd_base" "$key")
  words=("${(@z)binding}")
  if (( ${words[(Ie)-s]} )); then
    zle -U -- "${(g:ce:)${(Q)words[-1]}}"
    return 0
  fi
  original=${(Q)words[-1]}
  _easyCmd_call "$original" "$@"
}

# 下拉出现即接管鼠标；收起、补全、vicmd、执行和 Ctrl-C 后释放。
_easyCmd_mouse_on() {
  (( _easyCmd_mouse_enabled )) && return 0
  [[ -n ${terminfo[cup]} ]] || return 0
  print -rn -- $'\e[?1000h\e[?1006h' > /dev/tty
  _easyCmd_mouse_enabled=1
}

# 任何键盘操作、失效的鼠标事件或菜单退出都会打断连续点击。
_easyCmd_mouse_reset() {
  _easyCmd_mouse_pressed=0
  _easyCmd_mouse_double=0
  _easyCmd_click_time=0
}

_easyCmd_mouse_off() {
  _easyCmd_mouse_reset
  (( _easyCmd_mouse_enabled )) || return 0
  print -rn -- $'\e[?1000l\e[?1006l' > /dev/tty
  _easyCmd_mouse_enabled=0
}

_easyCmd_mouse_read() {
  (( PENDING || KEYS_QUEUED_COUNT )) || zselect -t 2 -r $ec_fd || return 1
  IFS= read -rk1 ec_char
}

# 读取 CSI 前缀之后的参数，不将终端回报当作输入文字；也消费迟到的回报。
_easyCmd_mouse_packet() {
  local -F deadline=$(( EPOCHREALTIME + 0.3 ))
  local -i ec_valid=1
  ec_packet=''
  while (( EPOCHREALTIME < deadline && ${#ec_packet} < 32 )); do
    _easyCmd_mouse_read || continue
    if [[ $ec_char == [0-9\;] ]]; then
      ec_packet+=$ec_char
    elif [[ $1 == *"$ec_char"* ]]; then
      ec_packet+=$ec_char
      (( ec_valid ))
      return
    elif [[ $ec_char == [[:print:]] ]]; then
      ec_valid=0
    else
      zle -U -- "$ec_char"
      return 1
    fi
  done
  return 1
}

_easyCmd_cursor_report() {
  emulate -L zsh
  local ec_fd ec_char ec_packet
  exec {ec_fd}</dev/tty || return 0
  { _easyCmd_mouse_packet R } always { exec {ec_fd}<&- }
  return 0
}

# 用 ZLE 自己的布局定位首项，兼容多行提示符、折行、中文和灰字。
# 临时把完全相同的显示文本交给 BUFFER，仅移动隐藏的光标；请求发出后立即
# 恢复原 BUFFER/CURSOR/POSTDISPLAY，再等待回报。绝不运行接受/编辑部件。
# DEC 私有 CPR (?6n) 不与 F3 / Ctrl-方向键冲突；无回报时不猜行号执行。
_easyCmd_mouse_origin() {
  local ec_saved_buffer=$BUFFER ec_saved_post=$POSTDISPLAY ec_saved_cursor=$CURSOR
  local -a ec_saved_highlights=("${region_highlight[@]}")
  local ec_input='' ec_replay='' ec_busy=$_easyCmd_busy
  local MATCH
  local -i MBEGIN MEND
  local -a match mbegin mend
  local -F deadline=$(( EPOCHREALTIME + 0.4 ))
  ec_first=0
  _easyCmd_busy=1
  {
    print -rn -u $ec_fd -- $'\e[?25l'
    BUFFER+=$POSTDISPLAY
    POSTDISPLAY=''
    CURSOR=$(( ${#ec_saved_buffer} + ${#ec_saved_post} - ${#_easyCmd_suffix} + 1 ))
    zle -R
    print -rn -u $ec_fd -- $'\e[?6n'
  } always {
    BUFFER=$ec_saved_buffer POSTDISPLAY=$ec_saved_post CURSOR=$ec_saved_cursor
    region_highlight=("${ec_saved_highlights[@]}")
    zle -R
    print -rn -u $ec_fd -- $'\e[?25h'
    _easyCmd_busy=$ec_busy
  }
  while (( EPOCHREALTIME < deadline && ${#ec_input} < 1024 )); do
    _easyCmd_mouse_read || continue
    ec_input+=$ec_char
    if [[ $ec_input =~ $'\e''\[\?([0-9]{1,5});([0-9]{1,5})(;[0-9]{1,5})?R' ]]; then
      ec_first=$((10#$match[1]))
      # 首项的光标必须处于第 1 列，且整个列表确实能放入当前屏幕。
      (( 10#$match[2] == 1 && ec_first > 0 && ec_first + ${#_easyCmd_shown} - 1 <= LINES )) || ec_first=0
      (( MBEGIN > 1 )) && ec_replay=${ec_input[1,MBEGIN-1]}
      (( MEND < ${#ec_input} )) && ec_replay+=${ec_input[MEND+1,-1]}
      [[ -n $ec_replay ]] && zle -U -- "$ec_replay"
      if [[ $BUFFER != "$ec_saved_buffer" || $POSTDISPLAY != "$ec_saved_post" ]] || (( CURSOR != ec_saved_cursor )); then
        ec_first=0
      fi
      return 0
    fi
  done
  # 等待期间的用户按键/鼠标释放回到 ZLE，不能吞键或填入报告正文。
  [[ -n $ec_input ]] && zle -U -- "$ec_input"
  return 1
}

_easyCmd_mouse() {
  emulate -L zsh
  local ec_fd ec_char ec_packet ec_command
  local -i ec_button ec_x ec_y ec_idx ec_first=0 ec_pressed=$_easyCmd_mouse_pressed
  local -i ec_width=$COLUMNS ec_height=$LINES ec_valid_click=0 ec_execute=0
  local -i ec_double=$_easyCmd_mouse_double
  local -F ec_now=$EPOCHREALTIME
  local -a match mbegin mend
  local MATCH
  exec {ec_fd}<>/dev/tty || return 0
  _easyCmd_mouse_pressed=0
  _easyCmd_mouse_double=0
  {
    _easyCmd_mouse_packet Mm || return 0
    [[ $ec_packet =~ '^([0-9]{1,3});([0-9]{1,5});([0-9]{1,5})([Mm])$' ]] || return 0
    ec_button=$((10#$match[1])) ec_x=$((10#$match[2])) ec_y=$((10#$match[3]))
    ec_char=$match[4]
    local ec_kind=$ec_char
    _easyCmd_mouse_pressed=0
    (( ec_button == 0 && ec_x >= 1 && ec_x < COLUMNS && ec_y >= 1 && ec_y <= LINES )) || return 0
    (( _easyCmd_mouse_enabled && _easyCmd_active && ! _easyCmd_closed && ${#_easyCmd_shown} )) || return 0
    [[ $BUFFER == "$_easyCmd_query" || ( $_easyCmd_pinned == 1 && $BUFFER == "$_easyCmd_pinned_buffer" ) ]] || return 0
    # 同批到达的快速点击可能跳过重绘；先恢复相同候选的布局，再查询真实位置。
    [[ -n $_easyCmd_suffix ]] || _easyCmd_compose mouse
    [[ -n $_easyCmd_suffix && $POSTDISPLAY == *"$_easyCmd_suffix" ]] || return 0
    (( BUFFERLINES <= LINES )) || return 0
    [[ $(command stty size <&$ec_fd 2>/dev/null) == "$ec_height $ec_width" ]] || return 0
    [[ $ec_kind == M ]] || (( ec_pressed )) || return 0
    _easyCmd_mouse_origin || return 0
    (( ec_first && COLUMNS == ec_width && LINES == ec_height )) || return 0
    [[ $(command stty size <&$ec_fd 2>/dev/null) == "$ec_height $ec_width" ]] || return 0
    ec_idx=$(( ec_y - ec_first + 1 ))
    (( ec_idx >= 1 && ec_idx <= ${#_easyCmd_shown} )) || return 0
    ec_command=$_easyCmd_shown[ec_idx]
    if [[ $ec_kind == M ]]; then
      # 只把上一轮完整点击与当前按下配对；拖动、跨项、跨屏幕位置不执行。
      if (( EASYCMD_DOUBLE_CLICK_MS > 0 && _easyCmd_click_time > 0 &&
            ec_now >= _easyCmd_click_time &&
            (ec_now - _easyCmd_click_time) * 1000 <= EASYCMD_DOUBLE_CLICK_MS &&
            _easyCmd_click_index == _easyCmd_top + ec_idx - 1 &&
            ec_y == _easyCmd_click_y && ec_x - _easyCmd_click_x <= 2 && _easyCmd_click_x - ec_x <= 2 )) &&
          [[ $ec_command == "$_easyCmd_click_command" && $BUFFER == "$ec_command" &&
             $_easyCmd_pinned == 1 && $_easyCmd_click_size == "$ec_height $ec_width" ]]; then
        _easyCmd_mouse_double=1
      fi
      _easyCmd_click_time=0
      _easyCmd_mouse_press_time=$ec_now
      _easyCmd_click_x=$ec_x
      _easyCmd_click_y=$ec_y
      _easyCmd_mouse_pressed=$ec_idx
      _easyCmd_mouse_buffer=$BUFFER
      _easyCmd_mouse_command=$ec_command
      _easyCmd_mouse_first=$ec_first
      _easyCmd_mouse_size="$ec_height $ec_width"
      _easyCmd_hover=$(( _easyCmd_top + ec_idx - 1 ))
      _easyCmd_engaged=0
      ec_valid_click=1
    elif (( ec_idx == ec_pressed && ec_first == _easyCmd_mouse_first )) &&
         [[ $BUFFER == "$_easyCmd_mouse_buffer" && $ec_command == "$_easyCmd_mouse_command" &&
            $_easyCmd_mouse_size == "$ec_height $ec_width" ]]; then
      _easyCmd_detach
      _easyCmd_preview=0
      BUFFER=$ec_command
      CURSOR=${#BUFFER}
      POSTDISPLAY=''
      _easyCmd_pinned=1
      _easyCmd_pinned_buffer=$BUFFER
      _easyCmd_engaged=0
      ec_valid_click=1
      # 仍需有效的第二次松开；长按或横向拖动只填入，不能直接执行。
      if (( ec_now >= _easyCmd_mouse_press_time &&
            (ec_now - _easyCmd_mouse_press_time) * 1000 <= EASYCMD_DOUBLE_CLICK_MS &&
            ec_x - _easyCmd_click_x <= 2 && _easyCmd_click_x - ec_x <= 2 )); then
        if (( ec_double )); then
          ec_execute=1
        else
          _easyCmd_click_time=$_easyCmd_mouse_press_time
          _easyCmd_click_command=$ec_command
          _easyCmd_click_index=$(( _easyCmd_top + ec_idx - 1 ))
          _easyCmd_click_size="$ec_height $ec_width"
        fi
      fi
    fi
  } always {
    (( ec_valid_click )) || _easyCmd_mouse_reset
    exec {ec_fd}>&-
  }
  if (( ec_execute )); then
    _easyCmd_dismiss
    # 与实际回车走相同原生部件，先关菜单，再接受输入；迟到点击不会再次执行。
    _easyCmd_native_key $'\r'
  fi
  return 0
}

# 只复制键表，不覆盖用户的 main / viins / emacs / vicmd，也不改 Esc。
_easyCmd_make_map() {
  emulate -L zsh
  local base=$1 map=easyCmd-map-$1 entry original key binding
  local -a words
  bindkey -N "$map" "$base"
  for entry in "${(@f)$(bindkey -L -M "$base")}"; do
    words=("${(@Q)${(z)entry}}")
    (( ${words[(Ie)-s]} )) && continue
    original=$words[-1]
    # Esc 保持原始部件，模式切换钩子负责摘掉列表。
    [[ ${words[-2]} == '^[' ]] && continue
    [[ $original == undefined-key ]] && continue
    zle -N "easyCmd-call:$original" _easyCmd_dispatch
    words[-1]=easyCmd-call:$original
    # bindkey -L 对 main 省略 -M，对 vicmd 使用 -a。
    words=("${(@)words:#-a}")
    if (( ${words[(Ie)-M]} )); then words[${words[(Ie)-M]}+1]=$map
    else words=(bindkey -M "$map" "${(@)words[2,-1]}"); fi
    "${words[@]}"
  done
  bindkey -M "$map" '\e[5~' easyCmd-history-up
  bindkey -M "$map" '\e[6~' easyCmd-history-down
  # vicmd 也用副本消费迟到的终端回报；所有编辑键继续委托原生部件。
  if [[ $base == vicmd ]]; then
    bindkey -M "$map" '\e[<' easyCmd-mouse
    bindkey -M "$map" '\e[?' easyCmd-cursor-report
    _easyCmd_maps[$base]=$map
    return 0
  fi
  for key in $'\e[A' $'\eOA'; do bindkey -M "$map" "$key" easyCmd-up; done
  for key in $'\e[B' $'\eOB'; do bindkey -M "$map" "$key" easyCmd-down; done
  for key in $'\e[C' $'\eOC'; do bindkey -M "$map" "$key" easyCmd-right; done
  bindkey -M "$map" '^I' easyCmd-tab
  bindkey -M "$map" '^M' easyCmd-enter
  bindkey -M "$map" '^J' easyCmd-enter
  bindkey -M "$map" '^G' easyCmd-cancel
  for key in {1..9}; do bindkey -M "$map" "\e$key" easyCmd-pick-$key; done
  bindkey -M "$map" '\e[<' easyCmd-mouse
  bindkey -M "$map" '\e[?' easyCmd-cursor-report
  _easyCmd_maps[$base]=$map
}

_easyCmd_init() {
  _easyCmd_preview=0
  _easyCmd_preview_suffix=''
  _easyCmd_retired_preview=''
  _easyCmd_saved_suggestion=''
  _easyCmd_expanded=0
  _easyCmd_pinned=0
  _easyCmd_recent=0
  _easyCmd_active=1
  _easyCmd_suffix=''
  _easyCmd_retired_suffix=''
  _easyCmd_closed=0
  _easyCmd_engaged=0
  _easyCmd_query=$'\0'
  _easyCmd_shown=()
  _easyCmd_maps=()
  _easyCmd_select
  return 0
}

_easyCmd_select() {
  (( _easyCmd_busy || ! _easyCmd_active )) && return 0
  case $KEYMAP in
    main|emacs|viins)
      _easyCmd_base=$KEYMAP
      [[ -n ${_easyCmd_maps[$KEYMAP]-} ]] || _easyCmd_make_map "$KEYMAP"
      zle -K "${_easyCmd_maps[$KEYMAP]}" ;;
    vicmd)
      _easyCmd_preview=0
      _easyCmd_pinned=0
      (( _easyCmd_recent )) && _easyCmd_query=$'\0'
      _easyCmd_recent=0
      _easyCmd_mouse_off
      _easyCmd_detach
      _easyCmd_shown=()
      _easyCmd_engaged=0
      _easyCmd_base=vicmd
      [[ -n ${_easyCmd_maps[vicmd]-} ]] || _easyCmd_make_map vicmd
      zle -K "${_easyCmd_maps[vicmd]}" ;;
    easyCmd-map-*) ;;
    *) _easyCmd_preview=0; _easyCmd_mouse_off; _easyCmd_detach; _easyCmd_shown=(); _easyCmd_engaged=0 ;;
  esac
  return 0
}

_easyCmd_finish() {
  # 关闭读端后，未完成的后台写入会退出；不会随下一条命令积累任务。
  _easyCmd_refresh_close
  _easyCmd_preview=0
  _easyCmd_pinned=0
  _easyCmd_recent=0
  _easyCmd_mouse_off
  _easyCmd_active=0
  _easyCmd_detach
  _easyCmd_shown=()
  [[ $KEYMAP == easyCmd-map-* ]] && zle -K "$_easyCmd_base"
  return 0
}

# autosuggestions 的同步/异步部件都在 highlighter 之后调用 zle -R。
# 在那次刷新之前合成列表，避免先擦掉列表、下一帧才补回的闪烁。
_easyCmd_suggest_highlight() {
  # Esc 的原生 autosuggest 包装器可能恢复进入 vicmd 前保存的 POSTDISPLAY。
  # 清理这份旧后缀；Esc 本身仍保持原绑定。
  if [[ ( $_easyCmd_base == vicmd || ( $KEYMAP != easyCmd-map-* && $KEYMAP != "$_easyCmd_base" ) ) &&
        -n $_easyCmd_retired_suffix && $POSTDISPLAY == *"$_easyCmd_retired_suffix" ]]; then
    POSTDISPLAY=${POSTDISPLAY%"$_easyCmd_retired_suffix"}
    [[ -n $_easyCmd_retired_preview && $POSTDISPLAY == "$_easyCmd_retired_preview" ]] && POSTDISPLAY=''
  fi
  _easyCmd_original_suggest_highlight "$@"
  if (( _easyCmd_active && _easyCmd_busy != 1 )) && [[ $_easyCmd_base != vicmd && ( $KEYMAP == easyCmd-map-* || $KEYMAP == "$_easyCmd_base" ) ]]; then
    _easyCmd_compose
  fi
  return 0
}

_easyCmd_precmd() {
  _easyCmd_preview=0
  _easyCmd_preview_suffix=''
  _easyCmd_pinned=0
  _easyCmd_recent=0
  _easyCmd_mouse_off
  # SIGINT 跳过 line-finish；ZLE 已把光标放在列表末尾的下一行。
  # 仅在这条退出路径按已知列表行数相对上移并清除，完全不查询绝对光标位置。
  if (( _easyCmd_active && ${#_easyCmd_shown} )) && [[ -n $_easyCmd_suffix ]]; then
    echoti cuu ${#_easyCmd_shown}
    echoti ed
  fi
  _easyCmd_active=0
  _easyCmd_suffix=''
  _easyCmd_shown=()
  _easyCmd_refresh_request
  if (( ${+functions[_zsh_autosuggest_highlight_apply]} )) &&
     [[ ${functions[_zsh_autosuggest_highlight_apply]} != *'_easyCmd_suggest_highlight'* ]]; then
    functions[_easyCmd_original_suggest_highlight]=$functions[_zsh_autosuggest_highlight_apply]
    functions[_zsh_autosuggest_highlight_apply]='_easyCmd_suggest_highlight "$@"'
  fi
  return 0
}

() {
  local action
  for action in up down right tab enter cancel pick-{1..9}; do
    zle -N easyCmd-$action _easyCmd_key
  done
  zle -N easyCmd-history-up _easyCmd_history_key
  zle -N easyCmd-history-down _easyCmd_history_key
  zle -N easyCmd-mouse _easyCmd_mouse
  zle -N easyCmd-cursor-report _easyCmd_cursor_report
  zle -N easyCmd-cache-ready _easyCmd_refresh_redraw
  add-zle-hook-widget line-init _easyCmd_init
  add-zle-hook-widget line-pre-redraw _easyCmd_draw
  add-zle-hook-widget line-finish _easyCmd_finish
  add-zle-hook-widget keymap-select _easyCmd_select
  zmodload zsh/terminfo
  add-zsh-hook precmd _easyCmd_precmd
  add-zsh-hook zshexit _easyCmd_refresh_close
  # 私有包装器必须在 autosuggestions 外层，建议插件只包装被委托的原生部件。
  if (( ${+ZSH_AUTOSUGGEST_IGNORE_WIDGETS} )); then
    ZSH_AUTOSUGGEST_IGNORE_WIDGETS+=( 'easyCmd-*' 'easyCmd-*' '_easyCmd_*' )
  fi
}

easyCmd-diag() {
  print -r -- "easyCmd v$_EASYCMD_VERSION; zsh $ZSH_VERSION; ${COLUMNS}x${LINES}"
  print -r -- "cached=${#_easyCmd_cache}; max_show=$EASYCMD_MAX_SHOW; renderer=ZLE; mouse=auto"
  print -r -- "history_limit=$EASYCMD_MAX_HIST; async=$_easyCmd_async_available; refreshing=$(( ${#_easyCmd_refresh_fd} > 0 ))"
}
