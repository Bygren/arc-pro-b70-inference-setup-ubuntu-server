#!/usr/bin/env bash
# patch_roocode_ripgrep.sh — Fix "Could not find ripgrep binary" in Roo Code for Linux
set -euo pipefail

RG_PATH="$(command -v rg || true)"
if [[ -z "$RG_PATH" ]]; then
    echo "⚠️ 'rg' (ripgrep) is not installed on this system."
    echo "Please install ripgrep first:"
    echo "  Ubuntu/Debian: sudo apt install -y ripgrep"
    echo "  Arch/Manjaro:  sudo pacman -S --noconfirm ripgrep"
    echo "  Fedora/RHEL:   sudo dnf install -y ripgrep"
    exit 1
fi

echo "✓ Found system ripgrep at: $RG_PATH"

EXT_DIRS=(
    "${HOME}/.vscode/extensions"
    "${HOME}/.vscode-server/extensions"
)

PATCHED=0

for base_dir in "${EXT_DIRS[@]}"; do
    if [[ -d "$base_dir" ]]; then
        while IFS= read -r -d '' ext_file; do
            if grep -q "Could not find ripgrep binary" "$ext_file"; then
                if grep -q "$RG_PATH" "$ext_file"; then
                    echo "✓ Already patched: $ext_file"
                    PATCHED=$((PATCHED + 1))
                else
                    echo "Patching: $ext_file ..."
                    cp "$ext_file" "${ext_file}.bak"
                    node -e "
const fs = require('fs');
let file = process.argv[1];
let rgPath = process.argv[2];
let content = fs.readFileSync(file, 'utf8');
let target = 'async function fne(t){let e=async r=>{let a=Uwe.join(t,r,S8i);return await Ln(a)?a:void 0};return ';
let replacement = 'async function fne(t){let e=async r=>{let a=Uwe.join(t,r,S8i);return await Ln(a)?a:void 0};return await Ln(\"' + rgPath + '\")?\"' + rgPath + '\":';
if (content.includes(target)) {
    fs.writeFileSync(file, content.replace(target, replacement), 'utf8');
    console.log('✓ Successfully patched with ' + rgPath);
} else {
    console.log('⚠️ Target signature not found, might be a different version.');
}
" "$ext_file" "$RG_PATH"
                    PATCHED=$((PATCHED + 1))
                fi
            fi
        done < <(find "$base_dir" -maxdepth 4 -name "extension.js" -path "*roo-cline*" -print0 2>/dev/null || true)
    fi
done

if [[ $PATCHED -eq 0 ]]; then
    echo "⚠️ No Roo Code extension directory found. Ensure Roo Code is installed in VS Code."
else
    echo ""
    echo "🎉 Done! Restart VS Code or run 'Developer: Reload Window' (Ctrl+Shift+P) for changes to take effect."
fi
