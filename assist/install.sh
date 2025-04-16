#!/bin/sh

# 获取当前目录的所有文件并拷贝到用户目录的 .shell_cli 文件夹中
current_dir=$(pwd)
target_dir="$HOME/.shell_cli"

# 创建目标目录（如果不存在）
mkdir -p "$target_dir"

# 拷贝当前目录的所有文件到目标目录
cp -v "$current_dir"/* "$target_dir"

# 向 .zshrc 文件中添加环境变量
zshrc_path="$HOME/.zshrc"
env_var="export ORBBEC_SHELL_PATH=~/.shell_cli/shell_cli.py"

# 检查是否已存在相同的环境变量设置
if ! grep -qF -- "$env_var" "$zshrc_path"; then
    # 如果不存在，则添加环境变量
    echo "$env_var" >> "$zshrc_path"
    echo "Environment variable added to .zshrc"
else
    echo "Environment variable already exists in .zshrc"
fi

# 提示用户重新加载 .zshrc 或重启终端
echo "Please reload your .zshrc file or restart your terminal to apply the changes."