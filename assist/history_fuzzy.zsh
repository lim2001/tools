#!/usr/bin/env zsh
# ============================================================
#  history_fuzzy.zsh  -  常驻式实时历史模糊下拉（zsh 原生）
#
#  行为：
#    * 输入任意字符（含空格的多词查询也支持）即在下方列出匹配的历史命令
#    * 每敲一个键全量重算重排，最多 HIST_FUZZY_MAX_SHOW(默认10) 条
#    * 分级 + 多维打分（维度彼此解耦，见下方「匹配规则」）
#    * Enter 只执行当前输入行，下拉仅作参考（不会误执行历史命令）
#    * 选中某一条（三选一）：
#        Ctrl-X 1..9  把列表第 N 条直接填进命令行 —— 不依赖终端，随时可用（推荐）
#        Ctrl-X f     大面板模式（需要装 fzf）：支持鼠标点击、滚轮、继续输入
#        鼠标直接点   实验性，默认关闭。zle 会吞掉 \e[M 的坐标字节导致读不到，
#                    详见模块 E2；想试就在 source 前加 HIST_FUZZY_MOUSE=auto
#    * 历史只扫描最近 HIST_FUZZY_MAX_HIST(默认10000) 条
#
#  ------------------------------------------------------------
#  匹配规则
#  ------------------------------------------------------------
#  级别（level）由高到低，级别差永远压倒打分，低级不可能越过高级：
#    L0 全词     cmd == query
#    L1 前缀     cmd 以 query 开头
#    L2 词首     分隔符(/ - 空格 等)后紧跟 query，如 "cd build" 的 build
#    L3 子串     cmd 任意位置含 query（含空格的查询也照样匹配）
#    L4 缩写     查询按空格拆词，每个词都命中 cmd 某个单词的开头
#                "b k" -> "./build.sh kernel"      "bu kernel" 同理
#                ——对应「只记得每个词开头几个字母」的自然输入习惯
#    L5 多词     每个 query 词在 cmd 里按顺序出现（位置不限）：
#                "git com" -> *git*com*，可命中 "git commit -m x"
#    L6 子序列   *q*u*e*r*y*（逐字符，空格也算字符）— 噪音最大，额外受跨度门槛约束
#
#  同级别内用打分排序。打分由若干「维度」加权求和，维度之间完全解耦：
#  每个维度只是一段代码片段，读写约定的几个变量，不感知其他维度的存在。
#  默认内置这些维度（变量 cand / hits / qc / toks 都已在求值上下文中准备好）：
#    + consec  相邻命中（连续段越长越好）
#    + bound   命中字符落在单词边界/行首的数量
#    + space   查询里的「空格」在 cmd 里也命中空格 → 分词结构对齐
#    + punct   查询里的 / - _ . : = @ 等标点命中同类字符 → 结构对齐
#    + abbrev  查询词里有多少个命中了 cmd 某个单词的开头（缩写/首字母）
#    - span    匹配跨度（首命中到末命中的距离，越小越紧凑）
#    - pos     首个命中字符的位置（越靠前越好）
#    - len     cmd 长度（同分时短的优先）
#  都相同时 → 最近使用优先（缓存下标小的在前）
#
#  追加自定义维度（不影响任何已有维度）：
#    _hist_fuzzy_dim_add mydim 600 '# 可读写 $cand / $hits / $qc
#                                    结果放进 _hist_fuzzy_dim_val'
#  权重全部可调；想退化成「纯最近使用优先」把各 W_* 设成 0 即可。
#  L6 额外门槛：跨度 > 查询长度 + HIST_FUZZY_SPAN_SLACK 的直接丢弃。
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
(( ${_HIST_FUZZY_VERSION:-0} >= 5 )) && return 0
typeset -g _HIST_FUZZY_VERSION=5

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
: ${HIST_FUZZY_FUZZY_MAX:=4}                      # L6 子序列最多补几条；设 0 = 完全不要
: ${HIST_FUZZY_FUZZY_MIN_LEN:=2}                  # 少于几个字符不做 L6
: ${HIST_FUZZY_SPAN_SLACK:=3}                     # L6 松散容忍：跨度 <= 查询长度 + 该值
: ${HIST_FUZZY_SCORE_LIMIT:=200}                  # 单级最多给多少条打分（性能护栏：
                                                  #   全量历史时调小=更快，调大=排序更准）
: ${HIST_FUZZY_LOOSE_LIMIT:=80}                   # 宽泛档位（L4/L5/L6 和 <=2 字符的查询）
                                                  #   的打分预算：这类查询候选极多，精排没意义
# 鼠标点选默认是关的。原因见模块 E2：zle 会把 \e[M 后面那 3 个坐标字节读进它自己的
# 输入队列，widget 里再也 read 不到（实测会卡住），所以纯 zsh 解析坐标不可靠。
# 想要「鼠标点/滚轮选」请用上面的 Ctrl-X f 面板（需要装 fzf，支持鼠标操作）。
: ${HIST_FUZZY_MOUSE:=off}                        # off / auto：auto=有列表就开 X10 鼠标报告
: ${HIST_FUZZY_MOUSE_TIMEOUT:=0.3}                # 定位光标位置(DSR)的等待秒数

# 打分权重
: ${HIST_FUZZY_W_LEVEL:=100000}                   # 每差一级的权重差
: ${HIST_FUZZY_W_CONSEC:=2000}                    # 连续命中
: ${HIST_FUZZY_W_BOUND:=1000}                     # 词边界命中
: ${HIST_FUZZY_W_SPACE:=1500}                     # 空格命中（分词结构对齐）
: ${HIST_FUZZY_W_PUNCT:=800}                      # 标点命中（/ - _ . : = @ 等结构对齐）
: ${HIST_FUZZY_W_ABBREV:=4000}                    # 缩写命中（每个查询词命中某个单词的开头）
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
typeset -ga _hist_fuzzy_toks                      # 查询按空格拆出的词
typeset -ga _hist_fuzzy_hits                      # 当前候选的命中位置（维度求值上下文）
typeset -g  _hist_fuzzy_cand=''                   # 当前候选串（维度求值上下文）
typeset -g  _hist_fuzzy_first=0
typeset -g  _hist_fuzzy_wn=0                      # 词级缩写：命中词数
typeset -g  _hist_fuzzy_wv=0                      # 词级缩写：含散乱惩罚的分值
typeset -g  _hist_fuzzy_last_histcmd=0
typeset -g  _hist_fuzzy_n_loose=0                 # 结果里 L6(子序列)项从第几条开始

# 鼠标点选状态
typeset -g  _hist_fuzzy_mouse=0                   # 是否已经让终端进入鼠标报告模式
typeset -ga _hist_fuzzy_shown                     # 当前实际画在屏幕上的候选（点击时要按它取）
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
#  模块 C：打分 —— 维度注册表（每个维度彼此解耦，可自由追加）
#
#  约定：打分流程先做一次字符扫描，得到「查询字符在候选里的命中位置」，
#  然后逐个调用已注册的维度，把各维度的加权结果累加。
#  维度函数在求值上下文中可直接读这些变量：
#      $_hist_fuzzy_cand   当前候选命令串
#      $_hist_fuzzy_hits   命中位置数组（1-based），与查询字符一一对应
#      $_hist_fuzzy_toks   查询按空格拆出的词
#      $_hist_fuzzy_first  首个命中位置
#      $_hist_fuzzy_span   匹配跨度
#  计算结果写回 $_hist_fuzzy_dim_val（整数）。
#  追加一个维度：写一个 _hist_fuzzy_dim_<名> 函数 + 一次 _hist_fuzzy_dim_add。
# ============================================================

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
  functions[_hist_fuzzy_score_impl]="() {
  local sc=\$HIST_FUZZY_BASE_SCORE
$body  _hist_fuzzy_sc=\$sc
  return 0
}"
}

# ---- 内置维度（正分 = 加分项）----
# 以「代码片段」注册，编译时被拼进 _hist_fuzzy_score_impl，没有函数调用开销。
# 片段里可直接用 $_hist_fuzzy_hits / $_hist_fuzzy_cand / $_hist_fuzzy_toks 等变量。

# 相邻命中：连续段越长说明查询串越完整
_hist_fuzzy_dim_add consec 2000 '
  local k v=0
  for (( k = 2; k <= ${#_hist_fuzzy_hits}; k++ )); do
    (( _hist_fuzzy_hits[k] == _hist_fuzzy_hits[k-1] + 1 )) && (( v += 1 ))
  done
  _hist_fuzzy_dim_val=$v'

# 命中字符落在单词边界（分隔符之后）或行首：语义相关性更强
_hist_fuzzy_dim_add bound 1000 '
  local k v=0 pc
  for k in $_hist_fuzzy_hits; do
    if (( k == 1 )); then
      (( v += 2 ))                                   # 行首加倍
    else
      pc=${_hist_fuzzy_cand[k-1]}
      [[ -z $pc || $pc != [[:alnum:]_.] ]] && (( v += 1 ))
    fi
  done
  _hist_fuzzy_dim_val=$v'

# 查询里的「空格」命中了候选里的空格 —— 说明两边分词结构对齐
_hist_fuzzy_dim_add space 1500 '
  local k v=0
  for (( k = 1; k <= ${#_hist_fuzzy_qchr}; k++ )); do
    [[ $_hist_fuzzy_qchr[k] == " " ]] && (( v += 1 ))
  done
  _hist_fuzzy_dim_val=$v'

# 查询里的标点命中了候选里的标点 —— 路径 / 选项结构对齐
_hist_fuzzy_dim_add punct 800 '
  local k v=0 c
  for (( k = 1; k <= ${#_hist_fuzzy_qchr}; k++ )); do
    c=$_hist_fuzzy_qchr[k]
    [[ $c != [[:alnum:]] && $c != " " ]] && (( v += 1 ))
  done
  _hist_fuzzy_dim_val=$v'

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

  # 查询按空格拆出的词（L4 缩写 / L5 多词匹配用；同时是打分维度的输入）
  _hist_fuzzy_toks=(${=q})
  # 注意：(b) 不会逐个转义数组元素，必须一个词一个词地转义，
  # 否则空格漏转义 → pattern 变成 *b k*（找连续空格子串），永远匹配不上
  local -a tpat
  local t
  for t in $_hist_fuzzy_toks; do tpat+=(${(b)t}); done
  local mpat="*${(j:*:)tpat}*"                      # 多词粗筛 pattern：*git*com*

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
  # L4/L5/L6 比较贵，且只在前面几档不够时才用 → 放到循环里惰性计算

  local -a seen=() final=()
  local -i level=0
  local name cand idx
  local -a grp rest2 tmp2
  local multi=$(( ${#_hist_fuzzy_toks} > 1 ))
  # 打分预算：查询越宽泛候选越多，全排一遍没意义（最终只显示前 10 条）
  local budget=$HIST_FUZZY_SCORE_LIMIT
  (( ${#q} <= 2 )) && budget=$HIST_FUZZY_LOOSE_LIMIT
  # 多词查询优化：L4 打分时顺手把「不是缩写」的候选连同分数记下来，
  # 下一级 L5 直接复用，避免同一批候选第二次遍历 + 第二次打分。
  local -A carry_map
  local -a carry_cand=()

  for name in A0 A1 A2 A3 A4 A5 A6; do
    if [[ $name == A4 ]]; then                       # L4 缩写：惰性计算
      (( multi )) || { (( level += 1 )); continue; }
      (( ${#final} >= HIST_FUZZY_MAX_SHOW )) && break
      grp=(${(M)_hist_fuzzy_cache:#${~mpat}})
    elif [[ $name == A5 ]]; then                     # L5 多词：复用 L4 的候选与分数
      (( multi )) || { (( level += 1 )); continue; }
      (( ${#final} >= HIST_FUZZY_MAX_SHOW )) && break
      grp=($carry_cand)
    elif [[ $name == A6 ]]; then                     # L6 子序列：惰性计算
      (( ${#q} >= HIST_FUZZY_FUZZY_MIN_LEN )) || { (( level += 1 )); continue; }
      (( ${#final} >= HIST_FUZZY_MAX_SHOW )) && break
      grp=(${(M)_hist_fuzzy_cache:#${~fpat}})
    else
      grp=(${(P)name})
    fi
    (( ${#grp} )) || { (( level += 1 )); continue; }

    local limit=$budget
    (( level >= 4 )) && limit=$HIST_FUZZY_LOOSE_LIMIT        # 宽泛档位用更小预算
    rest2=()
    local -i n=0
    for cand in $grp; do
      (( ${seen[(I)${cand}]} )) && continue                  # 高级已收录
      rest2+=($cand)
      n=$(( n + 1 ))
      (( n >= limit )) && break                              # 性能护栏
    done
    (( ${#rest2} )) || { (( level += 1 )); continue; }

    # 该级内部：多维打分排序
    local slack=$(( ${#q} + HIST_FUZZY_SPAN_SLACK ))
    tmp2=()
    idx=0
    for cand in $rest2; do
      idx=$(( idx + 1 ))
      local sc
      if [[ $name == A5 ]]; then
        sc=${carry_map[$cand]:-0}                            # L4 已经打过分
      else
        _hist_fuzzy_score "$cand" || continue
        sc=$_hist_fuzzy_sc
        if (( level == 4 )); then
          if ! _hist_fuzzy_is_abbrev "$cand"; then           # 不是完整缩写 → 留给 L5
            carry_map[$cand]=$sc
            carry_cand+=($cand)
            continue
          fi
        elif (( level == 6 )); then
          (( _hist_fuzzy_span > slack )) && continue          # 太松散，丢掉
          (( ${#tmp2} >= HIST_FUZZY_FUZZY_MAX )) && break     # L6 最多补这么几条
        fi
      fi
      (( sc += (6 - level) * HIST_FUZZY_W_LEVEL ))
      # key = 分数(降序) + 缓存下标补数(降序 ⇒ 最近使用在前)
      tmp2+=("${(l:6::0:)sc}${(l:4::0:)$(( 10000 - idx ))} $cand")
    done

    if (( level == 6 )); then _hist_fuzzy_n_loose=${#final}
    else _hist_fuzzy_n_loose=$(( HIST_FUZZY_MAX_SHOW + 1 )); fi

    # 注意：只有真正入选的才进 seen。被本级拒掉（如 L4 判不是完整缩写、
    # L6 判太松散）的命令，在更低一级里仍应出现，不能提前消耗掉。
    local -a ordered
    ordered=(${${(O)tmp2}#* })
    (( ${#ordered} )) && { final+=($ordered); seen+=($ordered); }

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
  _hist_fuzzy_mouse_off                            # 列表没了就别再占着鼠标
  _hist_fuzzy_shown=()
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

  # 记下真正画在屏幕上的行，鼠标点击时按它取命令
  _hist_fuzzy_shown=($cands)
  [[ $HIST_FUZZY_MOUSE == auto ]] && _hist_fuzzy_mouse_on
  return 0
}

# ============================================================
#  模块 E2：鼠标点选
# ------------------------------------------------------------
#  为什么不用 complist 的 menu-select：实测它在本机不会让终端进入鼠标报告
#  模式（只发 \e[?1h / \e[?2004h，没有任何 1000/1002/1006），点了没反应。
#  所以这里自己接管 X10 鼠标协议：
#    1) 列表出现时让终端开鼠标报告    \e[?1000h
#    2) 点击时终端会把 \e[M<b><x><y> 当成输入送进 zle
#    3) 绑定 \e[M 到本部件，再读 3 个字节解析行列
#    4) 用 \e[6n 查询当前光标所在行，反推点的是列表第几行
#    5) 命中就把该行命令填进 BUFFER，并立刻关掉鼠标报告
#  副作用：鼠标报告开启期间，终端的「鼠标拖拽选文本」会被吞掉
#          （绝大多数终端按住 Shift 拖拽仍可选）；tmux 里需要 set -g mouse on。
# ============================================================

_hist_fuzzy_mouse_on() {
  (( _hist_fuzzy_mouse )) && return 0
  _hist_fuzzy_mouse=1
  print -rn -- $'\e[?1000h'                        # X10 mouse tracking on
  return 0
}

_hist_fuzzy_mouse_off() {
  (( _hist_fuzzy_mouse )) || return 0
  _hist_fuzzy_mouse=0
  print -rn -- $'\e[?1000l'                        # off
  return 0
}

# 查询光标当前在第几行（DSR \e[6n -> 终端回 \e[<row>;<col>R）
_hist_fuzzy_cursor_row() {
  local ch buf='' tries=$(( HIST_FUZZY_MOUSE_TIMEOUT * 50 ))
  (( tries < 5 )) && tries=15
  print -rn -- $'\e[6n'
  while (( tries-- > 0 )); do
    read -t 0.05 -k 1 ch 2>/dev/null || continue
    buf+=$ch
    [[ $ch == R ]] && break
  done
  local nums=${buf//[^0-9\;]/}
  [[ $buf == *R* && $nums == *\;* ]] || return 1
  print -r -- ${nums%%;*}
}

# \e[M 之后还有 3 个字节（按键 / 列 / 行），读完再判断是否点中了列表某行
function hist-fuzzy-pick-mouse {
  local reply=''
  read -k 3 -r reply 2>/dev/null
  if (( ${#reply} < 3 )) || (( ! _hist_fuzzy_mouse )); then
    _hist_fuzzy_mouse_off
    return 0
  fi
  local btn=$(( $(( ##${reply[1]} )) - 32 ))       # 0/1/2 = 左中右键按下，3 = 松开
  local row=$(( $(( ##${reply[3]} )) - 32 ))       # 行(1 起)
  (( btn < 0 || btn > 3 )) && return 0             # 滚轮等其它事件忽略

  local row0
  row0=$(_hist_fuzzy_cursor_row 2>/dev/null) || { _hist_fuzzy_mouse_off; return 0; }
  _hist_fuzzy_mouse_off

  local n=${#_hist_fuzzy_shown}
  (( n )) || return 0
  local idx
  if [[ $HIST_FUZZY_PLACE == below ]]; then
    idx=$(( row - row0 ))                          # 列表在输入行下方：下一行即第 1 条
  else
    idx=$(( n - (row0 - row) + 1 ))                # 列表在输入行上方
  fi
  (( idx >= 1 && idx <= n )) || return 0

  LBUFFER=${_hist_fuzzy_shown[idx]}
  RBUFFER=''
  CURSOR=${#LBUFFER}
  _hist_fuzzy_clear
  return 0
}

# ---- 把光标处的第 N 条候选直接填进命令行（Ctrl-X 1..9）----
function hist-fuzzy-pick {
  local n=${1:-1}
  local -a cands
  cands=($_hist_fuzzy_shown)
  (( ${#cands} )) || cands=($_hist_fuzzy_result)
  if (( ${#cands} == 0 )); then
    zle -M '没有候选项'
    return 0
  fi
  if (( n > ${#cands} )); then
    zle -M "只有 ${#cands} 条候选"
    return 0
  fi
  LBUFFER=${cands[n]}
  RBUFFER=''
  CURSOR=${#LBUFFER}
  _hist_fuzzy_clear
  return 0
}

# ---- 大面板（需要 fzf）：支持鼠标点击、滚轮、再输入 ------------------------
# fzf 自己接管了 tty，鼠标事件由它处理，绕开 zle 读不到坐标的问题
function hist-fuzzy-panel {
  local picked
  picked=$(printf '%s\n' $_hist_fuzzy_cache \
             | fzf --scheme=history --height=40% --min-height=8 --reverse \
                   --no-sort --tiebreak=index --exact \
                   --prompt='history> ' --query="$LBUFFER" 2>/dev/null) || return 0
  [[ -n $picked ]] || return 0
  LBUFFER=$picked
  RBUFFER=''
  CURSOR=${#LBUFFER}
  zle -R
  return 0
}

# 手动开关 mouse 报告（HIST_FUZZY_MOUSE=auto 时用）：Ctrl-X m
function hist-fuzzy-mouse-toggle {
  if (( _hist_fuzzy_mouse )); then
    _hist_fuzzy_mouse_off
    zle -M ''
  else
    _hist_fuzzy_trigger
    if (( ${#_hist_fuzzy_shown} )); then
      _hist_fuzzy_mouse_on
      zle -M '鼠标点选：点列表某一行即可填入命令（再按一次 ^Xm 或按 Esc 退出）'
    else
      zle -M '当前没有候选项'
    fi
  fi
  return 0
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

if [[ -o interactive ]] && zle -l >/dev/null 2>&1; then
  # ---- 选中方式 1：Ctrl-X 1..9 直接把第 N 条候选填进命令行 ------------------
  # 不依赖终端、不依赖鼠标协议，任何环境都能用
  local _i _hist_fuzzy_cx=$'\x18'                  # ^X 前缀（=Ctrl-X）
  for _i in 1 2 3 4 5 6 7 8 9; do
    eval "function hist-fuzzy-pick-$_i { hist-fuzzy-pick $_i }"
    zle -N hist-fuzzy-pick-$_i
    bindkey -M emacs "$_hist_fuzzy_cx$_i" hist-fuzzy-pick-$_i 2>/dev/null
    bindkey -M viins "$_hist_fuzzy_cx$_i" hist-fuzzy-pick-$_i 2>/dev/null
  done
  unset _i _hist_fuzzy_cx

  # ---- 选中方式 2（可选）：装了 fzf 就支持鼠标点选/滚轮的大面板 --------------
  if (( ${+commands[fzf]} )) || [[ -e ${HOME}/.fzf.zsh ]]; then
    zle -N hist-fuzzy-panel
    bindkey -M emacs '^Xf' hist-fuzzy-panel 2>/dev/null
    bindkey -M viins '^Xf' hist-fuzzy-panel 2>/dev/null
  fi

  # ---- 选中方式 3（实验性）：X10 鼠标。默认关闭見 HIST_FUZZY_MOUSE=auto ----
  if [[ $HIST_FUZZY_MOUSE != off ]]; then
    zle -N hist-fuzzy-pick-mouse
    zle -N hist-fuzzy-mouse-toggle
    bindkey -M emacs '\e[M' hist-fuzzy-pick-mouse 2>/dev/null
    bindkey -M viins '\e[M' hist-fuzzy-pick-mouse 2>/dev/null
    bindkey -M emacs $'\x18m' hist-fuzzy-mouse-toggle 2>/dev/null
    bindkey -M viins $'\x18m' hist-fuzzy-mouse-toggle 2>/dev/null
  fi

  # ---- 与 zsh-autosuggestions 共存 -------------------------------------------
  # 它默认异步（zpty 回调）直接改写 POSTDISPLAY 来显示行内灰字建议，那段回调
  # 不在按键路径上、会在我们渲染之后把列表刷掉。关掉它的异步后，它改 POSTDISPLAY
  # 的时机回到 widget 阶段（早于 pre-redraw），我们的列表就不会被覆盖。
  # 代价：行内灰字建议让位给列表（两者功能重复，列表已经包含了它）。
  # 想保留异步（列表可能偶尔被闪掉）就设 HIST_FUZZY_ALLOW_ASYNC=1。
  (( ${+functions[_zsh_autosuggest_fetch]} )) && [[ -z $HIST_FUZZY_ALLOW_ASYNC ]] && \
    unset ZSH_AUTOSUGGEST_USE_ASYNC

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
      print "鼠标        : 模式=$HIST_FUZZY_MOUSE 已开启=$_hist_fuzzy_mouse"
      print "屏上候选    : ${#_hist_fuzzy_shown} 条（点击按这个取）"
      print "查询/词     : q=[$LBUFFER] toks=$_hist_fuzzy_toks"
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
