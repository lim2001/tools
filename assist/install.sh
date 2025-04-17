#!/bin/bash

SOURCE_FILE=".bash_aliases_install"
TARGET_FILE="$HOME/.bash_aliases"
BEGIN_MARK="# >>> BEGIN orbbec shell tool install aliases >>>"
END_MARK="# <<< END orbbec shell tool install aliases <<<"

# Ensure .bash_aliases exists
[ ! -f "$TARGET_FILE" ] && touch "$TARGET_FILE"

# Read source content without interpreting special characters
NEW_BLOCK=$(cat "$SOURCE_FILE")

# Extract existing block (including markers)
EXISTING_BLOCK=$(awk "/${BEGIN_MARK}/,/${END_MARK}/" "$TARGET_FILE")
EXISTING_BODY=$(echo "$EXISTING_BLOCK" | sed "1d;\$d")

# Determine whether to add or replace
if [ -z "$EXISTING_BLOCK" ]; then
    echo "[*] Installing..."
    {
        echo ""
        echo "$BEGIN_MARK"
        cat "$SOURCE_FILE"
        echo "$END_MARK"
    } >> "$TARGET_FILE"
    echo "[✔] Install aliases successfully."
elif [ "$EXISTING_BODY" != "$NEW_BLOCK" ]; then
    echo "[*] Alias block content changed. Replacing existing block..."
    cp "$TARGET_FILE" "$TARGET_FILE.bak"
    sed -i "/${BEGIN_MARK}/,/${END_MARK}/d" "$TARGET_FILE"
    {
        echo ""
        echo "$BEGIN_MARK"
        cat "$SOURCE_FILE"
        echo "$END_MARK"
    } >> "$TARGET_FILE"
    echo "[✔] Replacement complete. Backup saved as .bash_aliases.bak."
else
    echo "[✓] Alias block is already up to date. No changes made."
fi

############################################

# Define target tools path in user home
TARGET_DIR="$HOME/tools"

# Determine source tools path (from parent directory of this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SOURCE_DIR="$(realpath "$SCRIPT_DIR/../tools")"
SOURCE_DIR="$(realpath "$SCRIPT_DIR/../")"
echo "[→] Current path is $SOURCE_DIR, Tatget path is $TARGET_DIR"

# Step 0: Prevent source == target
if [ "$(realpath "$SOURCE_DIR")" = "$(realpath "$TARGET_DIR")" ]; then
    echo "[✔] Are the same: $SOURCE_DIR"
    echo "[✔] Install complete.  To apply the changes, please restart your terminal session "
    exit 1
fi

# Step 1: Check for existing ~/tools directory
if [ ! -d "$TARGET_DIR" ]; then
    echo "[+] ~/tools does not exist. Creating it..."
    mkdir -p "$TARGET_DIR"
else
    if [! -f "$TARGET_DIR/list_menu.py" ]; then
        echo "[✘] ~/tools folder conflict, please rename your tools folder. install fail"
        exit 1
    fi
fi

# Step 2: Copy files from source to target (overwriting if necessary)
echo "[→] Installing ..."
cp -rf "$SOURCE_DIR/"* "$TARGET_DIR/"

echo "[✔] Install complete.  To apply the changes, please restart your terminal session "
