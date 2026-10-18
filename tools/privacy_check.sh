#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# privacy_check.sh - keep personal data out of this (public) repository.
#
#     bash tools/privacy_check.sh --staged    what is about to be committed
#                                             (run by the pre-commit hook)
#     bash tools/privacy_check.sh --history   every commit, file contents and
#                                             author/committer e-mails (run by
#                                             the pre-push hook)
#
# The patterns live OUTSIDE the repository, so the private strings are never
# published themselves:
#     ~/p25t-backup/private-patterns.txt   (or the file in $P25T_PRIVATE_PATTERNS)
# one extended regular expression per line, matched without regard to case;
# lines starting with # and empty lines are ignored. Without that file the
# check refuses (it does not silently pass).
#
# Exit 0 = clean, 1 = something found (the commit/push is stopped),
# 2 = cannot check. Install the hooks with tools/install_privacy_hooks.sh.
set -u
PAT_FILE=${P25T_PRIVATE_PATTERNS:-$HOME/p25t-backup/private-patterns.txt}
MODE=${1:-}
TOP=$(git rev-parse --show-toplevel 2> /dev/null) || { echo "privacy_check: not inside a git repository" >&2; exit 2; }
cd "$TOP"

[ -f "$PAT_FILE" ] || {
    echo "privacy_check: $PAT_FILE is missing - cannot check, so refusing." >&2
    echo "  (create it: one pattern per line; see tools/privacy_check.sh)" >&2
    exit 2
}
PAT=$(mktemp)
trap 'rm -f "$PAT"' EXIT
grep -v -E '^[[:space:]]*(#|$)' "$PAT_FILE" > "$PAT"   # an empty line would match everything
[ -s "$PAT" ] || { echo "privacy_check: $PAT_FILE has no patterns - refusing." >&2; exit 2; }

found=0
report() { echo "PRIVATE DATA: $*" >&2; found=1; }

check_ident() {   # check_ident <what> <"Name <email>">
    if printf '%s\n' "$2" | grep -q -i -E -f "$PAT"; then
        report "$1 is '$2' - set your public address: git config user.email <ADDRESS>"
    fi
}

case "$MODE" in
--staged)
    check_ident "the author of this commit" "$(git var GIT_AUTHOR_IDENT | sed 's/>.*/>/')"
    check_ident "the committer of this commit" "$(git var GIT_COMMITTER_IDENT | sed 's/>.*/>/')"
    mapfile -d '' FILES < <(git diff --cached --name-only --diff-filter=ACMR -z)
    if [ "${#FILES[@]}" -gt 0 ]; then
        hits=$(git grep --cached -I -i -n -E -f "$PAT" -- "${FILES[@]}" 2> /dev/null)
        [ -z "$hits" ] || report "in the files being committed:"$'\n'"$hits"
    fi
    ;;
--history)
    hits=$(git rev-list --all | xargs -r git grep -I -i -l -E -f "$PAT" 2> /dev/null)
    [ -z "$hits" ] || report "in the history (commit:file):"$'\n'"$hits"
    idents=$(git log --all --format='%an <%ae>%n%cn <%ce>' | sort -u | grep -i -E -f "$PAT")
    [ -z "$idents" ] || report "as commit author/committer:"$'\n'"$idents"
    ;;
*)
    echo "usage: bash tools/privacy_check.sh --staged | --history" >&2
    exit 2
    ;;
esac

if [ "$found" -ne 0 ]; then
    echo "Stopped. Remove the private data (or fix the e-mail) and try again." >&2
    exit 1
fi
echo "privacy_check $MODE: clean"
exit 0
