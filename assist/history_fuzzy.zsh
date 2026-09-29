#!/usr/bin/env zsh
# ============================================================
#  history_fuzzy.zsh  -  常驻式实时历史模糊下拉（zsh 原生）
#
#  行为：
#    * 输入任意字符（含空格的多词查询也支持）即在下方列出匹配的历史命令
#    * 每敲一个键全量重算重排，最多 HIST_FUZZY_MAX_SHOW(默认10) 条
#    * 分级 + 多维打分（见下方「匹配规则」）
#    * Enter 只执行当前输入行，下拉仅作参考（不会误执行历史命令）
#    * 需要选中：Ctrl-X h 打开 complist 菜单，方向键 + 回车 填入命令行
#    * 历史只扫描最近 HIST_FUZZY_MAX_HIST(默认1000) 条
#
#  ------------------------------------------------------------
#  匹配规则（模块 C，独立打分，可单独测试）
#  ------------------------------------------------------------
#  级别由高到低（级别差永远压倒一切，低级不可能越过高级）：
#    L0 全词     cmd == query
#    L1 前缀     cmd 以 query 开头
#    L2 词首     分隔符(/ 空格 - 等)后紧跟 query，如 "cd build" 的 build
#    L3 子串     cmd 任意位置含 query（含空格的查询也照样匹配）
#    L4 多词     查询按空格拆成若干词，cmd 里按顺序都出现：
#                "git com" -> *git*com*，可命中 "git commit -m x"
#    L5 子序列   *q*u*e*r*y*（逐字符，空格也算一个字符）— 最容易产生噪音，
#                额外受跨度门槛约束，并且是唯一用暗灰色标示的档位
#
#  同级别内的多维打分（越大越靠前）：
#    + w_consec  相邻字符连续命中数（连续段越多越好）
#    + w_bound   命中字符落在词边界/行首的数量（词义相关度）
#    + w_space   查询里的「空格」在 cmd 里也命中了空格 —— 说明分词结构对齐，
#                语义权重最高（这是独立的一个维度，不是普通字符）
#    + w_punct   查询里的 / - _ . : = @ 等标点在 cmd 里命中同类字符 —— 结构对齐
#    - w_span    匹配跨度（首命中到末命中的距离，越小越紧凑）
#    - w_pos     首个命中字符的位置（越靠前越好）
#    - w_len     命令长度（同分时短的优先）
#  都相同时 → 最近使用优先（缓存下标小的在前）
#
#  权重全部可调；想退化成「纯最近使用优先」把 w_* 设成 0 即可。
#  L5 额外门槛：跨度 > 查询长度 + HIST_FUZZY_SPAN_SLACK 的直接丢弃。
#
#  渲染：POSTDISPLAY（默认，列表在输入行下方）或 PREDISPLAY（上方）
#        都由 zle 负责重绘与清除，不抢终端、不破坏回滚缓冲
#
#  可调参数（在 source 之前设置，或改完 source 一遍即可热更新）：
#    HIST_FUZZY_MAX_HIST / MAX_SHOW / MIN_LEN / PLACE
#    HIST_FUZZY_FUZZY_MAX / FUZZY_MIN_LEN / SPAN_SLACK
#    HIST_FUZZY_W_LEVEL / W_CONSEC / W_BOUND / W_SPAN / W_POS / W_LEN
#    HIST_FUZZY_IGNORE（黑名单命令名）
#
#  诊断：直接执行 histf-diag [查询词]
# ============================================================

# ---------- 模块 A：加载控制 ----------
# 用版本号而不是布尔量：改完文件再 source 能热替换，"source 了却没生效"的问题不再有
(( ${_HIST_FUZZY_VERSION:-0} >= 4 )) && return 0
typeset -g _HIST_FUZZY_VERSION=4

# ---------- 参数 ----------
: ${HIST_FUZZY_MAX_HIST:=10000}                   # 扫描最近多少条历史；实测全量(50000)
                                                  #   去重后约 2180 条唯一命令，单次匹配
                                                  #   10~35ms（见文件头注释），可接受
: ${HIST_FUZZY_MAX_SHOW:=10}
: ${HIST_FUZZY_MIN_LEN:=1}
: ${HIST_FUZZY_COLOR_TOP:=fg=green,bold}
: ${HIST_FUZZY_COLOR_REST:=fg=blue}
: ${HIST_FUZZY_COLOR_FUZZY:=fg=black,bold}        # L4 子序列项：更暗，一眼能区分
: ${HIST_FUZZY_PLACE:=below}                      # below=列表在输入行下方(默认) / above=上方
: ${HIST_FUZZY_FUZZY_MAX:=4}                      # L4 子序列最多补几条；设 0 = 完全不要
: ${HIST_FUZZY_FUZZY_MIN_LEN:=2}                  # 少于几个字符不做 L4
: ${HIST_FUZZY_SPAN_SLACK:=3}                     # L4 松散容忍：跨度 <= 查询长度 + 该值
: ${HIST_FUZZY_SCORE_LIMIT:=200}                  # 单级最多给多少条打分（性能护栏：
                                                  #   全量历史时调小=更快，调大=排序更准）
# 打分权重
: ${HIST_FUZZY_W_LEVEL:=100000}                   # 每差一级的权重差
: ${HIST_FUZZY_W_CONSEC:=2000}                    # 连续命中
: ${HIST_FUZZY_W_BOUND:=1000}                     # 词边界命中
: ${HIST_FUZZY_W_SPACE:=1500}                     # 空格命中（分词结构对齐，独立维度）
: ${HIST_FUZZY_W_PUNCT:=800}                      # 标点命中（/ - _ . : = @ 等结构对齐）
: ${HIST_FUZZY_W_SPAN:=50}                        # 跨度惩罚
: ${HIST_FUZZY_W_POS:=20}                         # 首命中位置惩罚
: ${HIST_FUZZY_W_LEN:=1}                          # 命令长度惩罚
: ${HIST_FUZZY_BASE_SCORE:=100000}                # 基准分，保证分数非负

typeset -ga HIST_FUZZY_IGNORE
(( ${#HIST_FUZZY_IGNORE} )) || HIST_FUZZY_IGNORE=(shl shh auto_history history_20)

# ---------- 内部状态 ----------
typeset -ga _hist_fuzzy_cache                     # 历史缓存：最新在前，已去重
typeset -ga _hist_fuzzy_result                    # 当前匹配结果
typeset -ga _hist_fuzzy_hl                        # 本次添加的 region_highlight
typeset -ga _hist_fuzzy_qpat                      # 查询拆成的单字符 pattern
typeset -ga _hist_fuzzy_qchr                      # 查询拆成的单字符（原样）
typeset -g  _hist_fuzzy_last_histcmd=0
typeset -g  _hist_fuzzy_n_loose=0                 # 结果里 L5(子序列)项从第几条开始
typeset -g  _hist_fuzzy_sc=0                      # _hist_fuzzy_score 的输出
typeset -g  _hist_fuzzy_span=0                    # _hist_fuzzy_score 的副产物
typeset -g  _hist_fuzzy_prev_key=''
typeset -gA _hist_fuzzy_orig                      # 被包装部件的原始实现

# ============================================================
#  模块 B：历史缓存
# ============================================================
_hist_fuzzy_refresh() {
  (( _hist_fuzzy_last_histcmd == ${HISTCMD:-0} && ${#_hist_fuzzy_cache} )) && return 0
  _hist_fuzzy_last_histcmd=${HISTCMD:-0}

  local -a h
  local first=1
  (( ${HISTCMD:-0} > HIST_FUZZY_MAX_HIST )) && first=$(( HISTCMD - HIST_FUZZY_MAX_HIST + 1 ))
  h=(${(f)"$(fc -l -n $first 2>/dev/null)"})

  # 兜底：内存历史不足 50 条时直接读文件（如 HISTSIZE 被设得很小 / 尚未加载）
  if (( ${#h} < 50 )) && [[ -n $HISTFILE && -f $HISTFILE ]]; then
    local -a raw h2=()
    raw=(${(f)"$(tail -n ${HIST_FUZZY_MAX_HIST} $HISTFILE 2>/dev/null)"})
    local x
    for x in $raw; do
      [[ $x =~ '^: [0-9]+:[0-9]+;' ]] && x=${x#*;}   # 去掉 extended history 前缀
      h2+=($x)
    done
    h=($h2)
  fi

  local -a h2
  h2=(${(Oa)h})                                      # 最新在前

  # 先规范化再最后去重：否则 "git commit" 和 "git commit " 会被当成两条
  local -a out=()
  local x cmd0
  for x in $h2; do
    x=${x%"${x##*[![:space:]]}"}                     # 去尾部空白
    x=${x//$'\t'/ }                                  # tab 统一成空格
    while [[ $x == *'  '* ]]; do x=${x//'  '/ }; done   # 压缩连续空格
    [[ $x == *[[:cntrl:]]* ]] && continue            # 含控制字符的脏记录
    [[ -z ${x//[[:space:]]/} ]] && continue          # 空行
    [[ $x == [\|\&\;]* ]] && continue                # 多行命令被拆出的续行片段
    [[ $x == *$'\\n'* ]] && continue                 # 多行命令
    [[ $x == *\\ ]] && continue                      # 以续行符结尾的残缺命令
    cmd0=${x%% *}
    (( ${HIST_FUZZY_IGNORE[(I)${cmd0}]} )) && continue
    out+=($x)
  done

  local -aU u
  u=($out)                                           # 去重，保留最新的那条
  _hist_fuzzy_cache=(${u[1,HIST_FUZZY_MAX_HIST]})
}

# ============================================================
#  模块 C：打分（纯逻辑，可单独测试）
#  输入：候选串；依赖全局 _hist_fuzzy_qpat（查询字符 pattern 数组）
#  输出：全局 _hist_fuzzy_sc（分数，越大越好）/ _hist_fuzzy_span（匹配跨度）
#       返回 0 表示命中所有查询字符，1 表示不是子序列
# ============================================================
_hist_fuzzy_score() {
  local cand=$1
  local -a qp qc
  qp=($_hist_fuzzy_qpat)                             # 查询字符（已转义成 pattern）
  qc=($_hist_fuzzy_qchr)                             # 查询字符（原样，用于判定字符类型）
  local rest=$cand pat pc ch
  local abs=0 p prev=-1 first=0 last=0 consec=0 bound=0 nsp=0 npun=0 ok=1
  local i

  for (( i = 1; i <= ${#qp}; i++ )); do
    pat=$qp[i]; ch=$qc[i]
    p=${rest[(i)$pat]}                               # 剩余串中下一个查询字符的位置
    (( p > ${#rest} )) && { ok=0; break; }           # 有一个字符找不到 → 非子序列
    abs=$(( abs + p ))
    (( prev == abs - 1 )) && (( consec += 1 ))       # 与上一个命中相邻
    pc=${cand[abs-1]}
    if (( abs == 1 )); then
      (( bound += 2 ))                               # 行首：权重加倍
    elif [[ -z $pc || $pc != [[:alnum:]_.] ]]; then
      (( bound += 1 ))                               # 词边界
    fi
    # ---- 字符类型维度（空格/标点单独计权，不按普通字符处理）----
    if   [[ $ch == ' ' ]];        then (( nsp  += 1 ))   # 空格命中：分词结构对齐
    elif [[ $ch != [[:alnum:]] ]]; then (( npun += 1 ))  # 标点命中：路径/选项结构对齐
    fi
    (( i == 1 )) && first=$abs
    last=$abs
    prev=$abs
    rest=${rest[p+1,-1]}
  done
  (( ok )) || return 1

  _hist_fuzzy_span=$(( last - first + 1 ))
  _hist_fuzzy_sc=$(( HIST_FUZZY_BASE_SCORE
                     + consec * HIST_FUZZY_W_CONSEC
                     + bound  * HIST_FUZZY_W_BOUND
                     + nsp    * HIST_FUZZY_W_SPACE
                     + npun   * HIST_FUZZY_W_PUNCT
                     - _hist_fuzzy_span * HIST_FUZZY_W_SPAN
                     - first * HIST_FUZZY_W_POS
                     - ${#cand} * HIST_FUZZY_W_LEN ))
  return 0
}

# ============================================================
#  模块 D：分级检索 + 排序
#  输入：LBUFFER；输出：_hist_fuzzy_result / _hist_fuzzy_n_loose
# ============================================================
_hist_fuzzy_build() {
  _hist_fuzzy_result=()
  _hist_fuzzy_n_loose=$(( HIST_FUZZY_MAX_SHOW + 1 ))          # 默认没有「凑数项」
  local q=$LBUFFER

  (( ${#_hist_fuzzy_cache} )) || _hist_fuzzy_refresh
  (( ${#q} < HIST_FUZZY_MIN_LEN )) && return 1
  # 注意：含空格的查询照样匹配（空格参与打分，见模块 C 的 w_space）

  # 查询预处理：拆成转义后的单字符 pattern + 原字符（判定空格/标点用）
  local -a cs
  cs=(${(s::)q})
  local c
  _hist_fuzzy_qpat=(); _hist_fuzzy_qchr=()
  for c in $cs; do _hist_fuzzy_qpat+=(${(b)c}); _hist_fuzzy_qchr+=($c); done

  local qp=${(b)q}
  local fpat="*${(j:*:)_hist_fuzzy_qpat}*"

  # 查询按空格拆出的词（L4 多词匹配用）
  local -a toks tpat
  toks=(${=q})
  tpat=()
  for c in $toks; do tpat+=(${(b)c}); done

  # ---- 分级候选 ----
  # 性能关键：只对缓存做「一次」子串 glob，L0/L1/L2 都从这个子集里再筛
  # （L0/L1/L2 必然是 L3 的子集），避免对全量缓存重复扫描 4 次。
  local -a A0 A1 A2 A3
  A3=(${(M)_hist_fuzzy_cache:#*${~qp}*})                     # L3 子串
  local x
  for x in $A3; do                                           # 一次遍历分三档
    if   [[ $x == $q ]]; then                     A0+=($x)   # L0 全词
    elif [[ $x == $q* ]]; then                    A1+=($x)   # L1 前缀
    elif [[ $x == *[^[:alnum:]_.]$q* ]]; then     A2+=($x)   # L2 词首
    fi
  done
  # L4 多词、L5 子序列比较贵，且只在前面几档不够时才用 → 放到循环里惰性计算

  local -a seen=() final=()
  local -i level=0
  local name cand idx
  local -a grp rest2 tmp2

  for name in A0 A1 A2 A3 A4 A5; do
    if [[ $name == A4 ]]; then                       # L4 多词：惰性计算
      (( ${#toks} > 1 )) || { (( level += 1 )); continue; }
      (( ${#final} >= HIST_FUZZY_MAX_SHOW )) && break
      grp=(${(M)_hist_fuzzy_cache:#*${(j:*:)tpat}*})
    elif [[ $name == A5 ]]; then                     # L5 子序列：惰性计算
      (( ${#q} >= HIST_FUZZY_FUZZY_MIN_LEN )) || { (( level += 1 )); continue; }
      (( ${#final} >= HIST_FUZZY_MAX_SHOW )) && break
      grp=(${(M)_hist_fuzzy_cache:#${~fpat}})
    else
      grp=(${(P)name})
    fi
    (( ${#grp} )) || { (( level += 1 )); continue; }

    rest2=()
    local -i n=0
    for cand in $grp; do
      (( ${seen[(I)${cand}]} )) && continue                  # 高级已收录
      rest2+=($cand)
      n=$(( n + 1 ))
      (( n >= HIST_FUZZY_SCORE_LIMIT )) && break             # 性能护栏
    done
    (( ${#rest2} )) || { (( level += 1 )); continue; }

    # 该级内部：多维打分排序；L5(子序列) 才额外受跨度门槛约束
    local slack=$(( ${#q} + HIST_FUZZY_SPAN_SLACK ))
    tmp2=()
    idx=0
    for cand in $rest2; do
      idx=$(( idx + 1 ))
      _hist_fuzzy_score "$cand" || continue
      if (( level == 5 )); then
        (( _hist_fuzzy_span > slack )) && continue           # 太松散，丢掉
        (( ${#tmp2} >= HIST_FUZZY_FUZZY_MAX )) && break      # L5 最多补这么几条
      fi
      local sc=$(( _hist_fuzzy_sc + (5 - level) * HIST_FUZZY_W_LEVEL ))
      # key = 分数(降序) + 缓存下标补数(降序 ⇒ 最近使用在前)
      tmp2+=("${(l:6::0:)sc}${(l:4::0:)$(( 10000 - idx ))} $cand")
    done

    if (( level == 5 )); then _hist_fuzzy_n_loose=${#final}
    else _hist_fuzzy_n_loose=$(( HIST_FUZZY_MAX_SHOW + 1 )); fi

    local -a ordered
    ordered=(${${(O)tmp2}#* })
    (( ${#ordered} )) && final+=($ordered)
    seen+=($rest2)

    (( ${#final} >= HIST_FUZZY_MAX_SHOW )) && break          # 级别差绝对优先，可安全停止
    (( level += 1 ))
  done

  _hist_fuzzy_result=(${final[1,HIST_FUZZY_MAX_SHOW]})
  (( ${#_hist_fuzzy_result} ))
}

# ============================================================
#  模块 E：渲染
# ============================================================
_hist_fuzzy_clear() {
  # 注意：补全菜单(menu-select)上下文里 PREDISPLAY/POSTDISPLAY 是只读的，
  # 直接赋值会报 read-only variable 并把菜单打断，所以必须吞掉错误
  { PREDISPLAY=''; POSTDISPLAY=''; } 2>/dev/null
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
  # 注意：某些终端/IDE 里 LINES 会是 0 或未导出，必须兜底，否则列表会被静默屏蔽
  local lines=${LINES}
  (( ${#lines} )) || lines=0
  (( lines < 8 )) && lines=24
  local maxn=$(( lines - 3 ))
  (( maxn < 1 )) && return 1
  (( ${#cands} > maxn )) && cands=(${cands[1,maxn]})

  local maxw=$(( ${COLUMNS:-80} - 1 ))
  local line off i=0 col
  local txt=''
  local -a hl=()

  # 颜色：第 1 条高亮最佳匹配；L4 子序列项用暗色标示「凑数」
  local -a cols=()
  for line in $cands; do
    i=$(( i + 1 ))
    if   (( i == 1 )); then                   cols+=($HIST_FUZZY_COLOR_TOP)
    elif (( i <= _hist_fuzzy_n_loose )); then cols+=($HIST_FUZZY_COLOR_REST)
    else                                      cols+=($HIST_FUZZY_COLOR_FUZZY); fi
  done

  if [[ $HIST_FUZZY_PLACE == below ]]; then
    # 向下：光标之后（列表在输入行下方）
    txt=$'\n'
    off=${#BUFFER}
    i=0
    for line in $cands; do
      (( ${#line} > maxw )) && line="${line[1,maxw]}"
      i=$(( i + 1 ))
      txt+=$line$'\n'
      hl+=("$(( off + 1 )) $(( off + 1 + ${#line} )) ${cols[i]}")
      off=$(( off + 1 + ${#line} ))
    done
    POSTDISPLAY=$txt
  else
    # 向上：提示符之后、输入行之前（列表在输入行上方）
    off=0
    i=0
    for line in $cands; do
      (( ${#line} > maxw )) && line="${line[1,maxw]}"
      i=$(( i + 1 ))
      txt+=$line$'\n'
      hl+=("$off $(( off + ${#line} )) ${cols[i]}")
      off=$(( off + ${#line} + 1 ))
    done
    PREDISPLAY=$txt
  fi

  _hist_fuzzy_hl=($hl)
  region_highlight+=($hl)
}

# ============================================================
#  模块 F：触发 + 部件
# ============================================================
_hist_fuzzy_trigger() {
  # 同一次按键里被多个入口调用时只算一次；
  # 但 key 里带上列表长度：一旦别的插件偷偷清掉 POSTDISPLAY(zsh-autosuggestions
  # 就会这么干)，key 就变了，下一次重绘会把列表补回来，做到自愈。
  local key="$BUFFER|$CURSOR|$_hist_fuzzy_last_histcmd|${#POSTDISPLAY}|${#PREDISPLAY}"
  [[ $key == $_hist_fuzzy_prev_key ]] && return 0
  _hist_fuzzy_clear
  if [[ -n $LBUFFER && ${#LBUFFER} -ge $HIST_FUZZY_MIN_LEN ]]; then
    _hist_fuzzy_build && _hist_fuzzy_render
  fi
  # 记录渲染「之后」的真实状态：列表一旦被别的插件清掉，下一次重绘就能自愈
  _hist_fuzzy_prev_key="$BUFFER|$CURSOR|$_hist_fuzzy_last_histcmd|${#POSTDISPLAY}|${#PREDISPLAY}"
  return 0
}

# 挂载 pre-redraw 钩子（幂等）。别的插件（语法高亮/autosuggestions）可能后来
# 抢注同一个钩子，这里采用「链式」方式：记录原实现并在我们的函数里先调用它。
_hist_fuzzy_hook_install() {
  local cur=${widgets[zle-line-pre-redraw]}
  [[ $cur == user:_hist_fuzzy_pre_redraw ]] && return 0
  local prev=${cur#user:}
  [[ $cur == builtin || -z $cur ]] && prev=''
  typeset -g _hist_fuzzy_preredraw_prev=$prev
  zle -N zle-line-pre-redraw _hist_fuzzy_pre_redraw
}

_hist_fuzzy_complete() {
  _hist_fuzzy_clear                       # 菜单弹出前先收起列表，避免画面重叠
  _hist_fuzzy_build || return 1
  (( ${#_hist_fuzzy_result} )) || return 1
  compadd -Q -o nosort -V history -a _hist_fuzzy_result
}

if [[ -o interactive ]] && zle -l >/dev/null 2>&1; then
  zmodload zsh/complist 2>/dev/null
  autoload -Uz _generic 2>/dev/null

  # ---- 与 zsh-autosuggestions 共存 -------------------------------------------
  # 它默认异步（zpty 回调）直接改写 POSTDISPLAY 来显示行内灰字建议，那段回调
  # 不在按键路径上、会在我们渲染之后把列表刷掉。关掉它的异步后，它改 POSTDISPLAY
  # 的时机回到 widget 阶段（早于 pre-redraw），我们的列表就不会被覆盖。
  # 代价：行内灰字建议让位给列表（两者功能重复，列表已经包含了它）。
  # 想保留异步（列表可能偶尔被闪掉）就设 HIST_FUZZY_ALLOW_ASYNC=1。
  (( ${+functions[_zsh_autosuggest_fetch]} )) && [[ -z $HIST_FUZZY_ALLOW_ASYNC ]] && \
    unset ZSH_AUTOSUGGEST_USE_ASYNC

  zle -C hist-fuzzy-menu menu-select _hist_fuzzy_complete
  zstyle ':completion:hist-fuzzy-menu:*' completer _hist_fuzzy_complete
  zstyle ':completion:hist-fuzzy-menu:*' matcher-list ''
  zstyle ':completion:hist-fuzzy-menu:*' format '%F{blue}history%f'
  bindkey -M emacs '^Xh' hist-fuzzy-menu 2>/dev/null
  bindkey -M viins '^Xh' hist-fuzzy-menu 2>/dev/null

  function _hist_fuzzy_pre_redraw {
    [[ -n $_hist_fuzzy_preredraw_prev ]] && zle $_hist_fuzzy_preredraw_prev
    _hist_fuzzy_trigger
  }

  # 每次命令结束后：刷新缓存、收起上一轮残留的列表、修复被抢走的 pre-redraw 钩子
  function _hist_fuzzy_precmd {
    _hist_fuzzy_refresh
    _hist_fuzzy_clear
    _hist_fuzzy_hook_install
  }
  (( ${precmd_functions[(I)_hist_fuzzy_precmd]} )) || precmd_functions+=(_hist_fuzzy_precmd)

  # 现场取证：输入若干字符后按 Esc+D（Alt+D），把 zle 的真实状态写到文件，便于排查
  function _hist_fuzzy_dump {
    _hist_fuzzy_trigger
    local f=${HIST_FUZZY_DUMP_FILE:-/tmp/histf_dump.txt}
    {
      print "===== $(date '+%F %T') ====="
      print "版本        : $_HIST_FUZZY_VERSION"
      print "BUFFER      : [$BUFFER]  CURSOR=$CURSOR"
      print "LINES/COLS  : $LINES / $COLUMNS"
      print "渲染位置    : ${HIST_FUZZY_PLACE}"
      print "PREDISPLAY  : ${#PREDISPLAY} 字节"
      print "POSTDISPLAY : ${#POSTDISPLAY} 字节"
      print "POSTDISPLAY 内容: ${POSTDISPLAY}"
      print "region_hl   : $region_highlight"
      print "cache       : ${#_hist_fuzzy_cache} 条"
      print "result      : ${#_hist_fuzzy_result} 条  n_loose=$_hist_fuzzy_n_loose"
      print "pre-redraw  : ${widgets[zle-line-pre-redraw]}"
      print "self-insert : ${widgets[self-insert]}"
      print "autosuggest : $(( ${+functions[_zsh_autosuggest_fetch]} ? 1 : 0 ))  异步=$(( ${+ZSH_AUTOSUGGEST_USE_ASYNC} ? 1 : 0 ))"
      print "---- 匹配结果 ----"
      print -l $_hist_fuzzy_result
    } > $f 2>&1
    zle -M "已写入 $f"
  }
  zle -N hist-fuzzy-dump _hist_fuzzy_dump
  # 注意：不能用 Esc 前缀（vi-mode 里 Esc 被占用）， ^Xd 在 emacs/vi 下都安全
  bindkey -M emacs '^Xd' hist-fuzzy-dump 2>/dev/null
  bindkey -M viins '^Xd' hist-fuzzy-dump 2>/dev/null
  bindkey -M vicmd '^Xd' hist-fuzzy-dump 2>/dev/null

  _hist_fuzzy_hook_install
fi

# ============================================================
#  模块 G：诊断（直接在命令行运行 histf-diag）
# ============================================================
histf-diag() {
  print "版本      : ${_HIST_FUZZY_VERSION:-未加载}"
  print "缓存条数  : ${#_hist_fuzzy_cache}  (HISTCMD=${HISTCMD:-0} HISTFILE=${HISTFILE:-未设置})"
  print "渲染位置  : ${HIST_FUZZY_PLACE:-未设置}   最多显示: ${HIST_FUZZY_MAX_SHOW:-未设置}"
  print "终端尺寸  : LINES=${LINES:-未设置} COLUMNS=${COLUMNS:-未设置}"
  print "pre-redraw: ${widgets[zle-line-pre-redraw]:-未注册}"
  print "编辑部件  : self-insert=${widgets[self-insert]:-无} / accept-line=${widgets[accept-line]:-无}"
  if (( ${+functions[_zsh_autosuggest_fetch]} )); then
    print "autosuggest: 已启用，异步=$(( ${+ZSH_AUTOSUGGEST_USE_ASYNC} ? 1 : 0 ))（异步=1 会抢 POSTDISPLAY）"
  else
    print "autosuggest: 未启用"
  fi
  print "POSTDISPLAY: ${#POSTDISPLAY} 字节"
  local q=${1:-build} saved=$LBUFFER
  LBUFFER=$q
  if _hist_fuzzy_build; then
    print "试查询[$q]: 命中 ${#_hist_fuzzy_result} 条（其中第 ${_hist_fuzzy_n_loose} 条起是子序列项）"
    print -l ${_hist_fuzzy_result[1,6]}
  else
    print "试查询[$q]: 无结果 —— 缓存为空？试试 bash 的 set -x 或检查 HISTFILE"
  fi
  LBUFFER=$saved
  return 0
}

_hist_fuzzy_refresh
