#!/usr/bin/env zsh
# ============================================================
#  需求与算法总览（改这个文件之前先读完这一段；AI 请以此段为准）
# ============================================================
#  【这是什么】一个纯 zsh 原生的「历史命令实时下拉」：在命令行下方常驻，
#  边打字边列出最可能想执行的历史命令，选中即填入命令行。不依赖 fzf / tmux。
#
#  【需求 —— 这几条是底线，任何改动都不能破坏】
#   R1 实时：每敲一个键全量重算重排，不能有可感知卡顿（实测 10~50ms/次，2000+ 条历史）
#   R2 安全：回车永远只执行「当前输入行」，下拉只是参考，绝不误执行历史命令
#   R3 选中即填：选中的那条必须整条填进 BUFFER、光标落到末尾 —— 回车即执行
#   R4 兼容：不许弄坏 zsh 原生补全（Tab / menu-select），也不许吞掉其它插件
#           写在首行的东西（zsh-autosuggestions 的行内灰字建议）。两者要能共存：
#           补全菜单激活时列表让位；行内建议接在光标后面，列表画在它下一行起
#   R5 可解释：排序必须能按「级别 → 打分维度」拆开讲清楚，方便调权重
#
#  【匹配算法】两阶段：先分级，再在同级内打分
#   阶段一 · 分级（level 差永远压倒打分，低级不可能越过高级）
#     L0 全词    cmd == query
#     L1 前缀    cmd 以 query 开头
#     L2 词首    分隔符(/ - 空格 等)后紧跟 query，如 "cd build" 里的 build
#     L3 子串    cmd 任意位置含 query（含空格的查询也照样匹配）
#     L4 缩写    查询按空格拆词，每个词都命中 cmd 某个单词的开头
#                "b k" / "bu kernel" -> "./build.sh kernel"
#                ——对应「只记得每个词开头几个字母」的自然输入习惯
#     L5 多词    每个 query 词在 cmd 里按顺序出现（位置不限）
#                "git com" -> *git*com*，可命中 "git commit -m x"
#     L6 子序列  *q*u*e*r*y*（逐字符，空格也算字符）——噪音最大，
#                额外门槛：跨度 > 查询长度 + HIST_FUZZY_SPAN_SLACK 的直接丢弃
#   阶段二 · 同级别内打分（各「维度」加权求和；维度彼此完全解耦）
#     每个维度只是一段代码片段，读约定变量、把结果写进 _hist_fuzzy_dim_val，
#     不感知其它维度的存在；全部维度会被编译进同一个函数里，零函数调用开销。
#     求值上下文里已经备好：$cand(候选) $hits(命中位置) $toks(查询词) $first $span
#     内置维度（+ 越大越好 / - 越小越好）：
#       + consec 相邻命中（连续段越长越好）
#       + bound  命中字符落在单词边界或行首的数量（行首加倍）
#       + space  查询里的「空格」在 cmd 里也命中空格 → 分词结构对齐
#       + punct  查询里的 / - _ . : = @ 等标点命中同类字符 → 结构对齐
#       + abbrev 查询词里有多少个命中了 cmd 某个单词的开头
#       - span   匹配跨度（首命中到末命中的距离，越小越紧凑）
#       - pos    首个命中字符的位置（越靠前越好）
#       - len    cmd 长度（同分时短的优先）
#     完全相同时 → 最近使用优先（缓存下标小的在前）
#     追加自定义维度（不动任何已有维度）：
#       _hist_fuzzy_dim_add mydim 600 '# 可读写 $cand / $hits / $toks
#                                        结果放进 _hist_fuzzy_dim_val'
#     权重全部可调；想退化成「纯最近使用优先」把各 W_* 设成 0 即可。
#
#  【渲染与选中】
#   * 渲染用 POSTDISPLAY（列表在输入行下方，默认）或 PREDISPLAY（上方），
#     由 zle 负责重绘与清除：不抢终端、不破坏回滚缓冲
#   * 选中方式（WindTerm 风格，列表始终有一条高亮"选中"）：
#     - ↑/↓ 在候选间移动高亮；→ 或 Ctrl-@ 把高亮那条填进命令行
#       （只动过选择后 → 才接管理我们的项，没动过时 → 原样放行给光标/autosuggest）
#     - Ctrl-X 1..9 直接填第 N 条（不依赖终端，最可靠）
#     - 鼠标：划过即反显高亮，点一下即填入（见 HIST_FUZZY_MOUSE，默认开）
#     - Ctrl-X f 用 fzf 大面板（装了 fzf 才有）
#   * 回车永远只执行「当前输入行」（R2），接受历史项请用上面的 ↑↓→ / Ctrl-X / 鼠标
#     鼠标直接点 zle 列表的原理性代价：zle 只能画字符网格，重绘要整块擦掉重画
#     （会闪），且鼠标报告开着时拖选文本被吞；想不闪就用 fzf 面板或 Ctrl-X n。
#   * 终端（WindTerm 等）自带的命令建议下拉是终端原生 GUI，比任何 shell
#     插件都稳 —— 二者并不冲突，可以同时用。
#   * 历史只扫描最近 HIST_FUZZY_MAX_HIST 条，且先规范化（去空白/压缩空格）再去重
#
#  【踩过的坑 —— 都是实测结论，别走回头路】
#   P1 同一个变量名在一个函数里被 local 两次，zsh 会把旧值打印到 stdout
#      （曾让每敲一键都往终端喷 k=3 / sc=502823）。所以：循环体内不许写 local，
#      所有变量在函数开头集中声明一次；维度片段里的局部变量要加维度名前缀。
#   P2 命令替换会把 stdout 截走：$(...) 里发的 \e[6n 查询根本到不了终端。
#      别用 row0=$(_hist_fuzzy_cursor_row) 这种写法。
#   P3 zle 部件里 read -k 只能读 zle 自己的输入队列，读不到「部件执行期间才到达」
#      的数据；部件里 print 的内容也不一定出得了门。所以查光标行只能在
#      非 zle 上下文（precmd）做，而且要用 read -k（它会临时切 raw 模式；
#      sysread 在 canonical 模式下读不到不带换行的回复）。
#   P4 补全菜单（compsys / menu-select）激活时 PREDISPLAY/POSTDISPLAY 是只读的，
#      直接赋值会报 read-only 并打断菜单 —— 渲染前要先探可写性。
#   P5 _hist_fuzzy_trigger 里 _hist_fuzzy_clear 必须在「key 没变就 return」之后调用：
#      clear 会顺手关掉鼠标报告，提前 return 就没人再把它开回来。
#   P6 region_highlight 的三个坑（悬停高亮就是被它们联手搞没的）：
#      a) 颜色规范必须写成 zsh 认得的样子：fg=xxx / bg=xxx / bold / standout ...
#         写成 fg-black,bg-white 会被 zsh 悄悄换成 none —— 表现是「悬停了却没高亮」。
#      b) 写进去的偏移量 zsh 会自己挪（实测写 "2 7"，下一帧读出来是 "3 8"；
#         挪不挪跟当时的 PREDISPLAY/POSTDISPLAY 有关，没有固定规律）。
#         所以只能「追加后立刻读回来」当凭据，清理时还要连 ±1 的形态一起认。
#      c) 清理要按区间(起:止)匹配，不能按整串匹配：颜色规范会被 zsh 归一化，
#         按整串比对必然漏删，条目一帧一帧累积 → 屏幕上出现脏高亮。
#   P7 鼠标点选错位（点第 3 个却填了第 5 个）的根因：DSR 光标查询在 precmd 里做，
#      那一刻光标还在「上一命令输出末尾」，并不是输入行；输入行还要往下挪
#      「先换一行(若光标不在行首) + 提示符占的行数」。之前漏掉提示符行数，多行提示符
#      （oh-my-zsh / powerlevel 等）下就整行整行地错。现在用 DSR 回的「列号」判断要不要
#      先换行，再用 _hist_fuzzy_prompt_lines（展开 PROMPT 数换行）补上提示符行数，
#      点选行号精确对齐。上方有输出 / 命令折行由 render 里的 wrap 项另行折算。
#
# ============================================================
#  用法速查
# ============================================================
#  选中：↑/↓ 移动高亮，→ 或 Ctrl-@ 接受高亮项 | Ctrl-X 1..9（填第 N 条）| 鼠标点列表行 | Ctrl-X f（fzf 面板）
#  诊断：histf-diag [查询词]       现场取证：输入后按 Ctrl-X d 写 /tmp/histf_dump.txt
#  可调（source 之前设置，改完 source 一遍即热更新）：
#    HIST_FUZZY_MAX_HIST / MAX_SHOW / MIN_LEN / PLACE / MOUSE
#    HIST_FUZZY_FUZZY_MAX / FUZZY_MIN_LEN / SPAN_SLACK / SCORE_LIMIT / LOOSE_LIMIT
#    HIST_FUZZY_W_LEVEL / W_CONSEC / W_BOUND / W_SPACE / W_PUNCT / W_ABBREV
#    HIST_FUZZY_W_SPAN / W_POS / W_LEN / HIST_FUZZY_IGNORE（黑名单命令名）
# ============================================================

# ---------- 模块 A：加载控制 ----------
# 用版本号而不是布尔量：改完文件再 source 能热替换，"source 了却没生效"的问题不再有
(( ${_HIST_FUZZY_VERSION:-0} >= 10 )) && return 0
typeset -g _HIST_FUZZY_VERSION=10

# ---------- 参数 ----------
: ${HIST_FUZZY_MAX_HIST:=10000}                   # 扫描最近多少条历史；实测全量(50000)
                                                  #   去重后约 2180 条唯一命令，单次匹配
                                                  #   10~35ms（见文件头注释），可接受
: ${HIST_FUZZY_MAX_SHOW:=10}
: ${HIST_FUZZY_MIN_LEN:=1}
: ${HIST_FUZZY_COLOR_TOP:=fg=green,bold}
: ${HIST_FUZZY_COLOR_REST:=fg=blue}
: ${HIST_FUZZY_COLOR_FUZZY:=fg=black,bold}        # L4 子序列项：更暗，一眼能区分
# 选中行(含鼠标悬停 / 方向键高亮)的高亮。用实打实的背景色，深底浅底都一眼可见；
# 不要用 standout（有些终端反显太弱、或和已有颜色叠加后看不出来）。
# 必须是 zsh 认得的规范写法（fg=xxx / bg=xxx / bold / standout ...）；
# 写错（如 fg-black,bg-white 少了等号）会被 zsh 悄悄换成 none —— 表现为「高亮了却没显示」。
: ${HIST_FUZZY_COLOR_HOVER:=bg=cyan,fg=black}
: ${HIST_FUZZY_PLACE:=below}                      # below=列表在输入行下方(默认) / above=上方
: ${HIST_FUZZY_FUZZY_MAX:=4}                      # L6 子序列最多补几条；设 0 = 完全不要
: ${HIST_FUZZY_FUZZY_MIN_LEN:=2}                  # 少于几个字符不做 L6
: ${HIST_FUZZY_SPAN_SLACK:=3}                     # L6 松散容忍：跨度 <= 查询长度 + 该值
: ${HIST_FUZZY_SCORE_LIMIT:=200}                  # 单级最多给多少条打分（性能护栏：
                                                  #   全量历史时调小=更快，调大=排序更准）
: ${HIST_FUZZY_LOOSE_LIMIT:=80}                   # 宽泛档位（L4/L5/L6 和 <=2 字符的查询）
                                                  #   的打分预算：这类查询候选极多，精排没意义
# 鼠标点选：auto = 列表出现即开鼠标报告（1000 按下 + 1003 移动），
#   鼠标划过列表哪一行，那一行就反显高亮；点一下即填入命令行。
# 代价（原理性，绕不开）：zle 只能在字符网格里画，重绘要整块擦掉重画 → 列表会闪；
#   鼠标报告开着时终端的「按住拖选文本」会被吞（多数终端按住 Shift 仍可选；
#   tmux 里要先 set -g mouse on）。终端不回 DSR（\e[6n）时插件自动放弃点选，
#   退回纯键盘操作，不会卡死。
# 受不了闪烁/拖选被吞 → HIST_FUZZY_MOUSE=off，或改用 fzf 大面板（Ctrl-X f）：
#   fzf 接管整个 tty 自己画 UI，点击/滚轮像素级精准、绝不闪烁；
#   终端（WindTerm 等）自带的命令建议下拉是原生 GUI 浮层，也可以同时用。
: ${HIST_FUZZY_MOUSE:=auto}                       # off / auto（默认 auto：悬停高亮 + 点选）
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
typeset -gA _hist_fuzzy_hl_ranges                 # 我们加进 region_highlight 的区间 "起:止"
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

# 现场调试：设了 HIST_FUZZY_DEBUG_LOG 才会写日志，默认完全不落盘
_hist_fuzzy_dbg() {
  [[ -n $HIST_FUZZY_DEBUG_LOG ]] && { print -r -- "$*" >> $HIST_FUZZY_DEBUG_LOG; } 2>/dev/null
  return 0
}

# 鼠标点选状态
typeset -g  _hist_fuzzy_mouse=0                   # 是否已经让终端进入鼠标报告模式
typeset -g  _hist_fuzzy_row=1                     # DSR 折算后的「输入行」所在屏幕行（见 _hist_fuzzy_query_row）
typeset -g  _hist_fuzzy_row_ok=1                  # 终端会不会回 DSR（不会就放弃鼠标点选）
typeset -g  _hist_fuzzy_row_miss=0                # 连续没回音的次数
typeset -ga _hist_fuzzy_shown                     # 当前实际画在屏幕上的候选（点击时要按它取）
typeset -g  _hist_fuzzy_prefix=''                 # 别人（autosuggestions 等）写在 POSTDISPLAY 里的行内建议
typeset -g  _hist_fuzzy_hover=0                   # 当前高亮(选中)的列表第几条（0 = 无；渲染时默认置 1）
typeset -g  _hist_fuzzy_engaged=0                 # 用户是否主动用方向键/鼠标移动过选择（未动则 → 不抢 autosuggest 的接受）
typeset -g  _hist_fuzzy_prompt_lines=1             # 提示符占几行（用于把 precmd 的 DSR 行号折算成真正的输入行）
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

  # 注意：所有局部变量只在函数开头声明一次。
  # zsh 里同一个变量名被 local 两次会把旧值打印到 stdout，循环体内尤其不能写 local。
  local -a h h2 raw out=()
  local -aU u
  local first=1 x cmd0
  (( ${HISTCMD:-0} > HIST_FUZZY_MAX_HIST )) && first=$(( HISTCMD - HIST_FUZZY_MAX_HIST + 1 ))
  h=(${(f)"$(fc -l -n $first 2>/dev/null)"})

  # 兜底：内存历史不足 50 条时直接读文件（如 HISTSIZE 被设得很小 / 尚未加载）
  if (( ${#h} < 50 )) && [[ -n $HISTFILE && -f $HISTFILE ]]; then
    raw=(${(f)"$(tail -n ${HIST_FUZZY_MAX_HIST} $HISTFILE 2>/dev/null)"})
    for x in $raw; do
      [[ $x =~ '^: [0-9]+:[0-9]+;' ]] && x=${x#*;}   # 去掉 extended history 前缀
      h2+=($x)
    done
    h=($h2)
  fi

  h2=(${(Oa)h})                                      # 最新在前

  # 先规范化再最后去重：否则 "git commit" 和 "git commit " 会被当成两条
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
  # 以下变量在下面的循环里反复使用，必须在这里集中声明一次
  local limit slack sc
  local -i n
  local -a ordered

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

    limit=$budget
    (( level >= 4 )) && limit=$HIST_FUZZY_LOOSE_LIMIT        # 宽泛档位用更小预算
    rest2=()
    n=0
    for cand in $grp; do
      (( ${seen[(I)${cand}]} )) && continue                  # 高级已收录
      rest2+=($cand)
      n=$(( n + 1 ))
      (( n >= limit )) && break                              # 性能护栏
    done
    (( ${#rest2} )) || { (( level += 1 )); continue; }

    # 该级内部：多维打分排序
    slack=$(( ${#q} + HIST_FUZZY_SPAN_SLACK ))
    tmp2=()
    idx=0
    for cand in $rest2; do
      idx=$(( idx + 1 ))
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
# 把 $1 里的条目追加进 region_highlight，并把「zsh 实际存下来的那几条」记进
# _hist_fuzzy_hl / _hist_fuzzy_hl_ranges。
#
_hist_fuzzy_hl_add() {
  local -i nb=${#region_highlight}
  region_highlight+=($@)
  _hist_fuzzy_hl=(${region_highlight[nb+1,-1]})     # 读回真实条目
  local -a p
  local r
  local -i s e
  for r in $_hist_fuzzy_hl; do
    p=(${=r})
    (( ${#p} >= 2 )) || continue
    s=${p[1]}; e=${p[2]}
    # 实测 zsh 会在重绘时把偏移量整体挪一格（我们写 "2 7"，下一次读就是 "3 8"，
    # 而且挪不挪跟当时的 PREDISPLAY/POSTDISPLAY 有关、没有固定规律）。
    # 所以 ±1 的两种形态都要登记，否则条目删不掉、会一帧一帧累积成脏高亮。
    _hist_fuzzy_hl_ranges[$s:$e]=1
    _hist_fuzzy_hl_ranges[$(( s + 1 )):$(( e + 1 ))]=1
    _hist_fuzzy_hl_ranges[$(( s - 1 )):$(( e - 1 ))]=1
  done
  return 0
}

# 把「我们」加进去的 region_highlight 条目摘掉。
# 按区间(起:止)匹配而不是按整串匹配：zsh 会把颜色规范归一化（写错还会变成 none），
# 按整串比对必然漏删，条目会一帧一帧累积在 region_highlight 里（屏幕上出现脏高亮）。
_hist_fuzzy_hl_drop() {
  (( ${#_hist_fuzzy_hl_ranges} )) || return 0
  local -a keep=() p
  local r
  for r in $region_highlight; do
    p=(${=r})
    if (( ${#p} >= 2 )) && (( ${+_hist_fuzzy_hl_ranges[${p[1]}:${p[2]}]} )); then
      continue                                     # 我们的条目：丢掉，别人的原样保留
    fi
    keep+=($r)
  done
  region_highlight=($keep)
  _hist_fuzzy_hl_ranges=()
  return 0
}

_hist_fuzzy_clear() {
  # 注意：补全菜单(menu-select)上下文里 PREDISPLAY/POSTDISPLAY 是只读的，
  # 直接赋值会报 read-only variable 并把菜单打断，所以必须吞掉错误
  { PREDISPLAY=''; POSTDISPLAY=''; } 2>/dev/null
  _hist_fuzzy_mouse_off                            # 列表没了就别再占着鼠标
  # 注意不要在这里清 _hist_fuzzy_hover：trigger -> clear -> render 会把悬停状态
  # 抹掉，悬停高亮就永远画不出来（只有真正换了输入时才由 trigger 清）
  _hist_fuzzy_shown=()
  _hist_fuzzy_hl_drop
  _hist_fuzzy_hl=()
}

_hist_fuzzy_render() {
  local -a cands
  cands=($_hist_fuzzy_result)
  (( ${#cands} )) || return 1

  # 默认高亮第 1 条（WindTerm 风格：始终有一条可见的"选中"），让用户一眼知道
  # 当前会选中哪条；之后鼠标划过 / 方向键移动会改到别的行。
  (( _hist_fuzzy_hover )) || _hist_fuzzy_hover=1
  (( _hist_fuzzy_hover > ${#cands} )) && _hist_fuzzy_hover=1

  # 屏幕高度不够时自动少显示几条（避免整屏被列表占满）
  # 注意：某些终端/IDE 里 LINES 会是 0 或未导出，必须兜底，否则列表会被静默屏蔽
  local lines=${LINES}
  (( ${#lines} )) || lines=0
  (( lines < 8 )) && lines=24
  local maxn=$(( lines - 3 ))
  # 鼠标点选是按「输入行行号 + 第几条」换算的，所以列表一旦放不下、被 zle 滚动，
  # 行号就对不上了。开鼠标时只画到屏幕底部为止，宁可少显示几条也要能点准。
  # 光标所在屏幕行要算上长命令的折行偏移（与 hist-fuzzy-pick-mouse 里的算法一致）
  if [[ $HIST_FUZZY_MOUSE != off ]]; then
    local rowc=$(( _hist_fuzzy_row + ( $#PREDISPLAY + CURSOR ) / ${COLUMNS:-80} ))
    local avail=$(( lines - rowc - 1 ))
    (( avail < maxn )) && maxn=$avail
  fi
  (( maxn < 1 )) && return 1
  (( ${#cands} > maxn )) && cands=(${cands[1,maxn]})

  # 补全菜单(compsys / menu-select)激活时 PREDISPLAY/POSTDISPLAY 是只读的。
  # 先探一下能不能写，写不进去就说明菜单还开着，这一帧直接让位给它。
  if [[ $HIST_FUZZY_PLACE == below ]]; then
    { POSTDISPLAY=$POSTDISPLAY; } 2>/dev/null || return 1
  else
    { PREDISPLAY=$PREDISPLAY; } 2>/dev/null || return 1
  fi

  local maxw=$(( ${COLUMNS:-80} - 1 ))
  local line off i=0 col r
  local txt=''
  local -a hl=() parts

  # 颜色：第 1 条高亮最佳匹配；L4 子序列项用暗色标示「凑数」
  local -a cols=()
  for line in $cands; do
    i=$(( i + 1 ))
    if   (( i == _hist_fuzzy_hover )); then   cols+=($HIST_FUZZY_COLOR_HOVER)  # 鼠标悬停
    elif (( i == 1 )); then                   cols+=($HIST_FUZZY_COLOR_TOP)
    elif (( i <= _hist_fuzzy_n_loose )); then cols+=($HIST_FUZZY_COLOR_REST)
    else                                      cols+=($HIST_FUZZY_COLOR_FUZZY); fi
  done

  _hist_fuzzy_dbg "RENDER n=${#cands} hover=$_hist_fuzzy_hover shown1=[${cands[1]}]"
  if [[ $HIST_FUZZY_PLACE == below ]]; then
    # 向下：光标之后（列表在输入行下方）
    # 第一段是别人的行内建议（紧跟光标），换行之后才是我们的列表
    txt=${_hist_fuzzy_prefix}$'\n'
    off=$(( ${#BUFFER} + ${#_hist_fuzzy_prefix} ))
    i=0
    for line in $cands; do
      (( ${#line} > maxw )) && line="${line[1,maxw]}"
      i=$(( i + 1 ))
      txt+=$line$'\n'
      hl+=("$(( off + 1 )) $(( off + 1 + ${#line} )) ${cols[i]}")
      off=$(( off + 1 + ${#line} ))
    done
    { POSTDISPLAY=$txt; } 2>/dev/null || return 1
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
    { PREDISPLAY=$txt; } 2>/dev/null || return 1
  fi

  _hist_fuzzy_hl_add $hl

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
  (( _hist_fuzzy_row_ok )) || return 0             # 终端不回 DSR → 点不准，干脆不接管鼠标
  _hist_fuzzy_mouse=1
  # 1003 = 任意移动跟踪：鼠标扫过列表行时终端会持续上报位置，用来做悬停高亮
  print -rn -- $'\e[?1000h\e[?1003h'
  return 0
}

_hist_fuzzy_mouse_off() {
  (( _hist_fuzzy_mouse )) || return 0
  _hist_fuzzy_mouse=0
  # 这里不要清 _hist_fuzzy_hover：每次重绘 trigger->clear 都会走到这里，
  # 一清悬停高亮就永远画不出来。悬停的失效交给 trigger 按「输入是否变了」判断。
  print -rn -- $'\e[?1003l\e[?1000l'
  return 0
}

# 查询光标当前在第几行（DSR \e[6n -> 终端回 \e[<row>;<col>R），结果写 $_hist_fuzzy_row
#
# 三个坑，都踩过：
#  1) 不能写成 row0=$(_hist_fuzzy_cursor_row)：命令替换会把 stdout 截走，
#     查询字节发不到终端，终端也就永远不会回 —— 表现为「点了没反应」。
#     同理结果不能用 print 回传，只能写全局变量 $_hist_fuzzy_row。
#     （也不要加 >/dev/tty：zle 部件里那个重定向会失败，查询同样发不出去。）
#  3) 回复是在 widget 执行期间才到达的，zle 主循环这会儿没在读，
#     这些字节进不了 zle 的输入队列 —— 所以 read -k 永远读不到，
#     必须用 sysread 直接从 fd 0 读。
# 注意：这个查询必须在「非 zle 上下文」做（precmd 里）。
# zle 部件里往终端写的东西出不去（实测：鼠标部件里 print 的 DSR 查询根本没到终端），
# 而且部件里 read -k 只能读 zle 自己的输入队列 —— 终端在部件执行期间才送来的回复
# 进不了那个队列，一样读不到。两条路都堵死，所以只能在 precmd 里问一次存起来。
_hist_fuzzy_query_row() {
  (( _hist_fuzzy_row_ok )) || return 1             # 已经判定这个终端不回 DSR
  local ch buf='' tries=20 r c
  print -rn -- $'\e[6n'
  # 必须用 read -k：终端这会儿是 canonical 模式，不带换行的回复根本不会被 read()
  # 交出来（sysread 也一样），read -k 会自己切成 raw 模式读完再恢复
  while (( tries-- > 0 )); do
    read -t 0.02 -k 1 ch 2>/dev/null && buf+=$ch
    [[ $buf == *R* ]] && break
  done
  local nums=${buf//[^0-9\;]/}
  if [[ $buf == *R* && $nums == *\;* ]]; then
    _hist_fuzzy_row_miss=0
    r=${nums%%;*}; c=${nums##*;}
    # 关键修正：precmd 此刻光标停在「上一命令输出的末尾」，并不是输入行。
    # 输入行 = 末尾行 + (若光标不在行首则需先换一行) + (提示符行数 - 1)。
    # 之前漏掉「提示符行数」，多行提示符（如 oh-my-zsh / powerlevel）下就会整行整行地错，
    # 表现就是「点第 3 个却填了第 5 个」。现在用 DSR 回的「列号」判断要不要先换行，
    # 再用 _hist_fuzzy_prompt_lines 把提示符占的行补上，点击行号精确对齐。
    local fwd=$(( c == 1 ? 0 : 1 ))
    _hist_fuzzy_row=$(( r + fwd + _hist_fuzzy_prompt_lines - 1 ))
    return 0
  fi
  # 没等到回复：它多半只是来晚了。必须把它收干净 —— 否则这几个字节会被 zle
  # 当成输入插进命令行（表现为命令行里莫名多出 "4R"）
  tries=6
  while (( tries-- > 0 )); do
    read -t 0.05 -k 1 ch 2>/dev/null || break
  done
  # 连着 3 次没回音才认定「这个终端不支持」：刚开 shell 那次常常拿不到回复，
  # 一次失败就永久放弃的话，鼠标点选会莫名其妙失灵
  (( ++_hist_fuzzy_row_miss >= 3 )) && _hist_fuzzy_row_ok=0
  return 1
}

# 悬停高亮：只换 region_highlight 里列表条目的颜色，绝不重画列表。
# 以前走 clear+build+render 整套重绘：鼠标每扫过一行，列表先整块擦掉再重建
# （build 还要 10~50ms），肉眼看就是列表一闪一闪。只改高亮、不动 POSTDISPLAY
# 就不会闪 —— zle 换 region_highlight 后 zle -R 只是重新上色。
# idx 没变的 motion 事件直接忽略（鼠标划过一行会产生一串 motion 事件）。
_hist_fuzzy_hover_set() {
  local idx=$1
  (( idx >= 0 && idx <= ${#_hist_fuzzy_shown} )) || idx=0
  (( idx == _hist_fuzzy_hover )) && return 0
  _hist_fuzzy_hover=$idx
  (( ${#_hist_fuzzy_hl} )) || return 0
  local -a cols=() parts new=()
  local r
  local -i i=0
  # 每条列表行的「正常颜色」，规则与 _hist_fuzzy_render 一致
  for r in $_hist_fuzzy_hl; do
    i=$(( i + 1 ))
    parts=(${=r})
    if   (( i == idx )); then                 new+=("${parts[1]} ${parts[2]} $HIST_FUZZY_COLOR_HOVER")
    elif (( i == 1 )); then                   new+=("${parts[1]} ${parts[2]} $HIST_FUZZY_COLOR_TOP")
    elif (( i <= _hist_fuzzy_n_loose )); then new+=("${parts[1]} ${parts[2]} $HIST_FUZZY_COLOR_REST")
    else                                      new+=("${parts[1]} ${parts[2]} $HIST_FUZZY_COLOR_FUZZY"); fi
  done
  # 先摘掉我们上一帧的条目（按区间匹配，见 _hist_fuzzy_hl_drop），
  # 再放回换色后的版本；其它插件（语法高亮等）的条目原样保留
  _hist_fuzzy_hl_drop
  _hist_fuzzy_hl_add $new
  zle -R
  return 0
}

# \e[M 之后还有 3 个字节（按键 / 列 / 行），按键字节减 32 后：
#   0/1/2 = 左中右键按下  -> 点中哪条就把哪条填进命令行
#   3     = 松开；35 = 鼠标移动（1003 模式）-> 都只做悬停高亮，不选中
#   其余（滚轮 64/65、带修饰键的按下 4/8/16...）一律忽略
function hist-fuzzy-pick-mouse {
  local reply=''
  read -k 3 -r reply 2>/dev/null
  if (( ${#reply} < 3 )) || (( ! _hist_fuzzy_mouse )); then
    _hist_fuzzy_mouse_off
    return 0
  fi
  local btn=$(( $(( ##${reply[1]} )) - 32 ))
  local row=$(( $(( ##${reply[3]} )) - 32 ))       # 行(1 起)
  _hist_fuzzy_dbg "EVT btn=$btn row=$row mouse=$_hist_fuzzy_mouse"

  # _hist_fuzzy_row 已经是折算后的「输入行」屏幕行（含提示符行数，见 query_row）。
  # 列表在输入行下方时，输入行若因过长折行会再往下挤，要把折行行数补上；
  # 列表在输入行上方时不需要补（PREDISPLAY 画在输入行之前）。
  local wrap=0
  [[ $HIST_FUZZY_PLACE == below ]] && wrap=$(( ( $#PREDISPLAY + CURSOR ) / ${COLUMNS:-80} ))
  local row0=$(( _hist_fuzzy_row + wrap ))

  local n=${#_hist_fuzzy_shown}
  local idx=0
  if (( n )); then
    if [[ $HIST_FUZZY_PLACE == below ]]; then
      idx=$(( row - row0 ))                        # 列表在输入行下方：下一行即第 1 条
    else
      idx=$(( n - (row0 - row) + 1 ))              # 列表在输入行上方
    fi
    (( idx >= 1 && idx <= n )) || idx=0            # 点/移到列表外面：视为没有悬停目标
  fi

  case $btn in
    0|1|2)                                         # 按下：选中（光标到末尾，回车即执行）
      _hist_fuzzy_dbg "  PRESS idx=$idx row0=$row0 shown1=[${_hist_fuzzy_shown[1]}]"
      (( idx )) || return 0                        # 点在列表外：忽略，鼠标保持开启
      _hist_fuzzy_mouse_off
      BUFFER=${_hist_fuzzy_shown[idx]}
      CURSOR=${#BUFFER}
      _hist_fuzzy_hover=0                          # 已经选完了，别把悬停状态带进下一轮
      _hist_fuzzy_clear
      _hist_fuzzy_shush
      return 0
      ;;
    3|35)                                          # 松开 / 移动：只刷新悬停高亮
      _hist_fuzzy_dbg "  MOTION idx=$idx hover=$_hist_fuzzy_hover"
      _hist_fuzzy_hover_set $idx
      _hist_fuzzy_dbg "  after hover=$_hist_fuzzy_hover"
      return 0
      ;;
    *) return 0 ;;
  esac
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
  # 填进命令行：光标落到末尾，回车即执行
  BUFFER=${cands[n]}
  CURSOR=${#BUFFER}
  _hist_fuzzy_clear
  _hist_fuzzy_shush
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
# 刚手动选完（鼠标点 / Ctrl-X n）：把 key 记成「已经渲染过空列表」，
# 这样下一轮重绘不会立刻又把列表弹回来，得用户继续输入才重新出现
_hist_fuzzy_shush() {
  _hist_fuzzy_prev_key="$BUFFER|$CURSOR|$_hist_fuzzy_last_histcmd|0|0|0"
}

_hist_fuzzy_trigger() {
  # 同一次按键里被多个入口调用时只算一次；
  # 但 key 里带上列表长度：一旦别的插件偷偷清掉 POSTDISPLAY(zsh-autosuggestions
  # 就会这么干)，key 就变了，下一次重绘会把列表补回来，做到自愈。
  # key 带上悬停行号：鼠标换行悬停时靠它触发重绘换高亮
  local base="$BUFFER|$CURSOR|$_hist_fuzzy_last_histcmd|${#POSTDISPLAY}|${#PREDISPLAY}"
  local key="$base|$_hist_fuzzy_hover"
  # 状态没变就什么都不做。注意一定要在 _hist_fuzzy_clear 之前返回：
  # clear 会顺手关掉鼠标报告，提前 return 的话就没人把它再开回来了
  # （表现为「按了一下无关的键之后，鼠标点选就失灵」）。
  [[ $key == $_hist_fuzzy_prev_key ]] && return 0
  # 除了悬停行号以外其它状态都变了 → 这是新的输入，鼠标悬停位置已经没有意义
  if [[ $base != ${_hist_fuzzy_prev_key%|*} ]]; then
    _hist_fuzzy_dbg "CLRHOVER base=[$base] prev=[${_hist_fuzzy_prev_key%|*}]"
    _hist_fuzzy_hover=0
    _hist_fuzzy_engaged=0                        # 换了输入，方向键/鼠标的"主动选择"状态作废
  fi

  # 原生补全（Tab / menu-select）激活时，列表一律让位：既不抢屏，也不干扰补全菜单。
  # compstate 只有在补全进行中才存在，平时是未设置状态。
  if (( ${+compstate} )) && [[ -n $compstate[context] ]]; then
    return 0
  fi

  # 行内建议（zsh-autosuggestions 等）也写在 POSTDISPLAY 里。
  # 先把它抠出来留着，重绘时接在光标后面再换行画列表 —— 两边各占一段，互不覆盖。
  #
  # 判断依据（必须严格，否则会越滚越大）：
  #   * 我们渲染的输出 = 建议 + \n + 列表，一定含换行
  #   * 别人的行内建议是单行（autosuggestions 不换行）
  # 以前只用「是否以旧前缀开头」判断，结果建议一变（用户继续输入时建议会缩短），
  # 「建议+旧列表」整块不再以旧前缀开头，就被当成新建议整段保留 ——
  # 列表从此一帧叠一帧，屏幕上滚出一大块重复内容（用户截图里的上下两大块）。
  local sugg=''
  if [[ $HIST_FUZZY_PLACE == below && -n $POSTDISPLAY ]]; then
    if [[ $POSTDISPLAY != *$'\n'* ]]; then
      sugg=$POSTDISPLAY                            # 单行：是别人的行内建议，接住
    elif [[ -n $_hist_fuzzy_prefix && $POSTDISPLAY == $_hist_fuzzy_prefix* ]]; then
      sugg=$_hist_fuzzy_prefix                     # 我们上一帧的输出：只取建议那一段
    fi
    # 其余情况（多行又对不上上一帧前缀）：是被别的插件改过的混合体，整块丢弃重建
  fi
  _hist_fuzzy_prefix=$sugg

  _hist_fuzzy_clear
  _hist_fuzzy_dbg "TRIG base=[$base] hover=$_hist_fuzzy_hover"
  if [[ -n $LBUFFER && ${#LBUFFER} -ge $HIST_FUZZY_MIN_LEN ]]; then
    _hist_fuzzy_build && _hist_fuzzy_render
  fi
  # 记录渲染「之后」的真实状态：列表一旦被别的插件清掉，下一次重绘就能自愈。
  # 格式必须和上面的 key 一致（也含悬停段）—— 否则 base 比较永远不等，
  # 悬停状态每帧都被当「新输入」清掉，高亮就画不出来（踩过）。
  _hist_fuzzy_prev_key="$base|$_hist_fuzzy_hover"
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

# ---- 与原生补全（compsys / menu-select）共存 --------------------------------
# 补全菜单要占屏幕，且激活期间 PREDISPLAY/POSTDISPLAY 是只读的，所以这里包一层：
# 触发补全前先把列表收起来让位；万一菜单还开着，_hist_fuzzy_render 探测到写不进去
# 也会自己放弃这一帧，不会打出 read-only 报错、不会打断菜单。
function _hist_fuzzy_complete_wrapper {
  local orig=${_hist_fuzzy_orig[$WIDGET]:-}
  _hist_fuzzy_clear
  if [[ $orig == user:* ]]; then
    zle ${orig#user:}                              # 原来的插件实现（链式调用）
  else
    zle .$WIDGET                                   # 内建实现
  fi
  return 0
}

if [[ -o interactive ]] && zle -l >/dev/null 2>&1; then
  # 先算提示符占几行：点选行号要折算成真正的输入行（见 _hist_fuzzy_query_row）。
  # 展开 % 转义后数换行；空提示符按 1 行算。
  local _pl=$(print -Pn -- "${PROMPT:-}" 2>/dev/null)
  _hist_fuzzy_prompt_lines=$(( $(printf '%s' "$_pl" | tr -cd '\n' | wc -c) + 1 ))

  # ---- 与 compsys 共存：把这几个补全部件包一层（幂等）----------------------
  local _w
  for _w in expand-or-complete menu-complete menu-expand-or-complete \
            reverse-menu-complete list-choices menu-select complete-word \
            accept-and-menu-complete; do
    [[ -z ${widgets[$_w]} ]] && continue
    [[ ${widgets[$_w]} == user:_hist_fuzzy_complete_wrapper ]] && continue
    _hist_fuzzy_orig[$_w]=${widgets[$_w]}
    zle -N $_w _hist_fuzzy_complete_wrapper
  done
  unset _w

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

  # ---- 选中方式 4（WindTerm 风格）：方向键移动选择 + → / Ctrl-@ 接受 ----------
  # 列表出现时，↑/↓ 在候选间移动高亮（可见的选中条），→ 或 Ctrl-@ 把高亮那条填进
  # 命令行。列表不存在时，↑/↓/→ 原样放行给「原本绑定到这些键的部件」
  # （历史浏览 / 光标右移 / zsh-autosuggestions 的 → 接受等），所以不干扰原生补全与 autosuggest。
  # 为避免「只是敲字、还没动选择」时 → 误伤 autosuggest 的接受，只有用户主动用
  # ↑/↓/鼠标移动过选择（_hist_fuzzy_engaged）后，→ 才接受我们的高亮项。
  # 先记下同名键原本绑定的部件，fallback 时委托给它，避免抢原生行为。
  local _ob
  _ob=$(bindkey -M emacs $'\e[A' 2>/dev/null); _hist_fuzzy_orig[__up]=${_ob##* }
  _ob=$(bindkey -M emacs $'\e[B' 2>/dev/null); _hist_fuzzy_orig[__down]=${_ob##* }
  _ob=$(bindkey -M emacs $'\e[C' 2>/dev/null); _hist_fuzzy_orig[__right]=${_ob##* }
  function hist-fuzzy-up {
    if (( ${#_hist_fuzzy_shown} )); then
      local _n
      if (( _hist_fuzzy_hover > 1 )); then _n=$(( _hist_fuzzy_hover - 1 )); else _n=${#_hist_fuzzy_shown}; fi
      _hist_fuzzy_engaged=1
      _hist_fuzzy_hover_set $_n          # 内部会设 _hist_fuzzy_hover 并重画高亮
      return 0
    fi
    zle ${_hist_fuzzy_orig[__up]:-up-line-or-history} 2>/dev/null || true
    return 0
  }
  function hist-fuzzy-down {
    if (( ${#_hist_fuzzy_shown} )); then
      local _n
      if (( _hist_fuzzy_hover < ${#_hist_fuzzy_shown} )); then _n=$(( _hist_fuzzy_hover + 1 )); else _n=1; fi
      _hist_fuzzy_engaged=1
      _hist_fuzzy_hover_set $_n
      return 0
    fi
    zle ${_hist_fuzzy_orig[__down]:-down-line-or-history} 2>/dev/null || true
    return 0
  }
  function hist-fuzzy-accept {
    # 列表在、且用户主动选过 → 接受高亮项；否则委托给原本绑定到 → 的部件
    # （通常是 forward-char 或 zsh-autosuggestions 的 autosuggest-accept），不抢原生行为。
    if (( ${#_hist_fuzzy_shown} && _hist_fuzzy_engaged && _hist_fuzzy_hover )); then
      BUFFER=${_hist_fuzzy_shown[_hist_fuzzy_hover]}
      CURSOR=${#BUFFER}
      _hist_fuzzy_hover=0; _hist_fuzzy_engaged=0
      _hist_fuzzy_clear
      _hist_fuzzy_shush
      return 0
    fi
    zle ${_hist_fuzzy_orig[__right]:-forward-char} 2>/dev/null || true
    return 0
  }
  zle -N hist-fuzzy-up
  zle -N hist-fuzzy-down
  zle -N hist-fuzzy-accept
  for _m in emacs viins; do
    bindkey -M $_m $'\e[A' hist-fuzzy-up     2>/dev/null   # ↑
    bindkey -M $_m $'\e[B' hist-fuzzy-down   2>/dev/null   # ↓
    bindkey -M $_m $'\e[C' hist-fuzzy-accept 2>/dev/null   # →
  done
  unset _m _ob
  # Ctrl-@ 无论是否 engaged 都能接受当前高亮（多一个不抢原生键的快捷键）
  bindkey -M emacs '^@' hist-fuzzy-accept 2>/dev/null
  bindkey -M viins '^@' hist-fuzzy-accept 2>/dev/null

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
    # 鼠标点选要知道输入行在屏幕第几行，只能在非 zle 上下文问；这里顺手问一次
    [[ $HIST_FUZZY_MOUSE != off ]] && _hist_fuzzy_query_row 2>/dev/null
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
