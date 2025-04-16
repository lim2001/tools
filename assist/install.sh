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
    echo "[*] Alias block not found. Appending to the end of .bash_aliases..."
    {
        echo ""
        echo "$BEGIN_MARK"
        cat "$SOURCE_FILE"
        echo "$END_MARK"
    } >> "$TARGET_FILE"
    echo "[✔] Block added successfully."
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
SOURCE_DIR="$(realpath "$SCRIPT_DIR/../tools")"

# Step 1: Check for existing ~/tools directory
if [ ! -d "$TARGET_DIR" ]; then
    echo "[+] ~/tools does not exist. Creating it..."
    mkdir -p "$TARGET_DIR"
else
    if [ ! -f "$TARGET_DIR/list_menu.py" ]; then
        echo "[✘] ~/tools already exists, but list_menu.py is missing."
        echo "    Possible conflict with an existing folder. Aborting."
        exit 1
    fi
fi

# Step 2: Copy files from source to target (overwriting if necessary)
echo "[→] Copying files from $SOURCE_DIR to ~/tools ..."
cp -rf "$SOURCE_DIR/"* "$TARGET_DIR/"

echo "[✔] Copy complete. ~/tools is up to date."
