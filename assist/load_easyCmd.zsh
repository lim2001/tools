#!/usr/bin/env zsh
# easyCmd 加载入口：由 .zshrc 自动 source，不需要单独执行。
# 安装器负责写入配置；核心按本文件所在目录定位，移动安装包也能加载。
[[ -o interactive && -o zle ]] || return 0
() {
  local plugin="${1:A:h}/easyCmd.zsh"
  if [[ ! -r $plugin ]]; then
    print -u2 -- "easyCmd: 找不到核心脚本 $plugin"
    return 1
  fi
  source "$plugin"
} "${(%):-%x}"
