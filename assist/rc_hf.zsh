# 在用户真实配置（oh-my-zsh + vi-mode + ys 主题）之后加载历史模糊下拉。
# 单独成一个文件，rc 里一句 source 即可：
#   [ -f ~/tools/assist/rc_hf.zsh ] && source ~/tools/assist/rc_hf.zsh
#
# 为什么拆成独立文件（2026-10-29 用真实 rc 副本在 pty 里实测）：
#   用 source 加载时，zsh 会先完整读取 .zshrc 的最后一段（不低于约 256 字节）再解析。
#   如果这段里出现引号不配对之类的小笔误，错误会发生在「还没轮到 source 这一行」，
#   于是 source 不执行、插件不生效、rc 后面几行也一起不执行，而且提示符看上去一切正常，
#   很难发现。拆成独立文件后，.zshrc 本身只剩一行普通的测试+source，不会再被这种问题连累。
#   排查方法：`zsh -n ~/.zshrc` 静默无输出才算语法正确。

# 缺省值（要改就在这上面加一行；插件里用的是 `:=`，已设置的不覆盖）
# HIST_FUZZY_MAX_SHOW=10
# HIST_FUZZY_MOUSE=auto
# HIST_FUZZY_DEBUG_LOG=/tmp/histf_trace.txt   # 只写调试日志（排查用，平时别开）

# 注意：这里写 $HOME/… 而不是 ~/… —— 赋值语句里 ~ 不展开，后面 `[[ -r $HIST_FUZZY_SELF ]]`
#   永远为假，插件就不会被 source（2026-10-29 实测踩到的坑）。
HIST_FUZZY_SELF=$HOME/tools/assist/history_fuzzy.zsh

# ZLE 没起来（非交互 / zsh -f）就什么都不做
if [[ ! -o zle ]]; then
  return 0
fi

# 诊断：记录加载结果，排查时 `cat ${HIST_FUZZY_BOOT_LOG:-/tmp/histf_boot.txt}`
{
  print -r -- "===== $(date '+%F %T') boot rc_hf ====="
  print -r -- "source 前 self-insert=[${widgets[self-insert]}] keymap=$KEYMAP zsh=$ZSH_VERSION"
} >> ${HIST_FUZZY_BOOT_LOG:-/tmp/histf_boot.txt} 2>&1

if [[ -r $HIST_FUZZY_SELF ]]; then
  source $HIST_FUZZY_SELF
else
  print -r -- "找不到 $HIST_FUZZY_SELF（检查路径）" >> ${HIST_FUZZY_BOOT_LOG:-/tmp/histf_boot.txt} 2>&1
  print -r -- "history_fuzzy.zsh 加载失败：找不到插件文件" >&2
  return 1
fi

{
  print -r -- "source 完 版本=$_HIST_FUZZY_VERSION 函数数=${#${(k)functions[(I)_hist_fuzzy*]}} up=[${widgets[hist-fuzzy-up]}] sel=[${widgets[self-insert]}]"
} >> ${HIST_FUZZY_BOOT_LOG:-/tmp/histf_boot.txt} 2>&1
