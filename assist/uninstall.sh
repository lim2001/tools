#!/bin/bash


TARGET_FILE="$HOME/.bash_aliases"
BEGIN_MARK="# >>> BEGIN orbbec shell tool install aliases >>>"
END_MARK="# <<< END orbbec shell tool install aliases <<<"

# Check if the target file exists
if [ ! -f "$TARGET_FILE" ]; then
    echo "[✘] $TARGET_FILE does not exist. Nothing to uninstall."
    exit 0
fi

# Check if the custom block exists
if grep -q "$BEGIN_MARK" "$TARGET_FILE" && grep -q "$END_MARK" "$TARGET_FILE"; then
    echo "[*] Found custom alias block. Removing it..."
    cp "$TARGET_FILE" "$TARGET_FILE.bak"
    sed -i "/${BEGIN_MARK}/,/${END_MARK}/d" "$TARGET_FILE"
    echo "[✔] Custom block removed. Backup saved as .bash_aliases.bak"
else
    echo "[✓] No custom alias block found. Nothing to remove."
fi
