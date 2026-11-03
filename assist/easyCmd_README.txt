easyCmd — zsh 实时历史命令菜单

安装 / 复制到其他电脑
1. 将 easyCmd.zsh、load_easyCmd.zsh、install_easyCmd.sh 放在同一文件夹。
2. 目标电脑先装好 zsh；不需要 Oh My Zsh、Python、Node.js，也不需要联网安装本插件。
3. 双击 install_easyCmd.sh 并选择“运行”，或在终端执行：
   bash install_easyCmd.sh
   若文件管理器把脚本打开成文本，请选择“在终端运行”或使用上面的命令。
4. 安装器会复制到 ~/.local/share/easyCmd，备份并更新 .zshrc。
   支持环境变量 ZDOTDIR 指定配置目录；重复安装不会重复添加配置。
   终端中安装后会进入一个已配置的 zsh；以后打开 zsh 自动启用。
   不会更改系统默认 Shell。安装前已经打开的其他 zsh 窗口可执行：
   source "$HOME/.local/share/easyCmd/load_easyCmd.zsh"

load_easyCmd.zsh 是自动加载入口，不需要用户单独执行。
测试目录仅供开发，不需要复制到目标电脑。
仅安装、不进入新 Shell：bash install_easyCmd.sh --no-shell

使用
输入时匹配历史；匹配结果统一按最后一次使用的先后排列，最近使用的在前。
前缀、子串、模糊匹配不再区分排序优先级；长短命令平权，没有长度扣分。
重复命令仅保留最近的一条；再次执行后移到前面。
空输入按 ↑/↓ 显示最近历史；不统计使用频次。
↑/↓ 选择，真实输入和光标保留，未确认的候选以灰字预览。
Tab/→ 确认候选；主动选择后 Enter 执行候选，否则执行真实输入。
鼠标单击填入但不执行，列表保留供再次选择；Ctrl-G 收起。
初始 10 行，第 11 条扩展至最多 20 行，此后滚动；小终端按可用高度显示。
PageUp/PageDown 调取原生历史；Esc 保持原生 vi 行为。
未选择菜单时 Tab/→ 保持用户原有的补全行为。

配置（在 .zshrc 的 easyCmd 加载块之前设置）
EASYCMD_MAX_SHOW=20
EASYCMD_COLOR_HOVER=bg=23,fg=255
EASYCMD_COLOR_PREVIEW=fg=8
诊断命令：easyCmd-diag

当前运行环境是 zsh，不能直接 source 到 Bash。
从旧名称升级时，安装器替换常见旧加载行；当前窗口加载新版会清理旧钩子。
旧 HIST_FUZZY_* 配置会在升级时迁移到 EASYCMD_*；新配置请使用 EASYCMD_*。
