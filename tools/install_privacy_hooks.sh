#!/bin/bash
# install_privacy_hooks.sh - make git run tools/privacy_check.sh by itself:
#   pre-commit: checks what is being committed (files and your e-mail)
#   pre-push:   checks the whole history before anything leaves the PC
# Run once in each clone (hooks are not part of what git copies):
#
#     bash tools/install_privacy_hooks.sh
#
# Existing hooks of the same name are kept as <hook>.pre-privacy.
set -eu
TOP=$(git rev-parse --show-toplevel)
HOOKS=$(git rev-parse --git-path hooks)
case "$HOOKS" in /*) ;; *) HOOKS=$TOP/$HOOKS ;; esac
mkdir -p "$HOOKS"
PAT_FILE=${P25T_PRIVATE_PATTERNS:-$HOME/p25t-backup/private-patterns.txt}

for h in pre-commit pre-push; do
    case $h in pre-commit) mode=--staged ;; pre-push) mode=--history ;; esac
    f=$HOOKS/$h
    if [ -e "$f" ] && ! grep -q privacy_check.sh "$f"; then
        mv "$f" "$f.pre-privacy"
        echo "kept the old hook as $f.pre-privacy"
    fi
    cat > "$f" <<EOT
#!/bin/sh
# installed by tools/install_privacy_hooks.sh
exec bash "\$(git rev-parse --show-toplevel)/tools/privacy_check.sh" $mode
EOT
    chmod 755 "$f"
    echo "installed: $f ($mode)"
done

[ -f "$PAT_FILE" ] || echo "WARNING: $PAT_FILE does not exist yet - every commit will be refused until it does"
echo "--- a first check of the whole history:"
bash "$TOP/tools/privacy_check.sh" --history
