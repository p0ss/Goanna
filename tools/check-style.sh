#!/usr/bin/env bash
# Goanna text style lint. See docs/style.md.
#
# Checks Goanna's own text (not the submodules, not vendored code) for:
#   - em dashes and the "--" stand in
#   - smart quotes, ellipsis characters, non breaking spaces
#   - common American spellings in prose
#
# It is a lint, not a gate. It will occasionally flag a legitimate quotation
# or an API name. Fix the prose, or say in the pull request why you did not.
#
# Exit status: 0 clean, 1 findings.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

fail=0

# Goanna's own text only. Excluded:
#   luanti/, godot-cpp/  submodules, not ours
#   src/transplant/      upstream Luanti code, kept byte identical on purpose
#   build/, .godot/      generated
#   LICENSE              the LGPL text, verbatim
#   docs/style.md        has to quote the characters it bans
#   this script          same
files() {
    git ls-files -- \
        ':!:luanti/**' ':!:godot-cpp/**' ':!:build/**' \
        ':!:src/transplant/**' \
        ':!:project/.godot/**' ':!:*.import' ':!:LICENSE' \
        ':!:docs/style.md' ':!:tools/check-style.sh' \
        '*.md' '*.gd' '*.h' '*.cpp' '*.cmake' 'CMakeLists.txt' '*.sh' \
        '*.gdextension' '*.godot' 2>/dev/null
}

report() {
    local label="$1" pattern="$2"
    local hits
    hits=$(files | xargs -r grep -nP "$pattern" 2>/dev/null)
    if [ -n "$hits" ]; then
        printf '\n%s\n' "$label"
        printf '%s\n' "$hits" | sed 's/^/  /'
        fail=1
    fi
}

report "em dash (U+2014). Use a comma, a full stop, a colon or brackets." \
       '\x{2014}'
report "'--' used as an em dash. Same rule." \
       '\S\s--\s\S'
report "smart quotes or ellipsis. Use straight quotes and full stops." \
       '[\x{2018}\x{2019}\x{201C}\x{201D}\x{2026}]'
report "non breaking or zero width space." \
       '[\x{00A0}\x{200B}\x{FEFF}]'
report "trailing whitespace." \
       ' +$'

# American spellings. Prose only. Markdown is checked in full; code files are
# checked on comment lines alone, because identifiers legitimately carry
# American spelling (Godot's Color, Luanti's getNeighbors, normalize,
# serialize). src/transplant is excluded from every check above, because it
# is upstream Luanti code and must stay byte identical apart from the
# documented changes.
AMERICAN='\b(color|colors|colored|coloring|behavior|behaviors|neighbor|neighbors|center|centers|centered|centering|meters|liter|liters|fiber|organiz(e|ed|es|ing|ation)|recogniz(e|ed|es|ing)|analyz(e|ed|es|ing)|optimiz(e|ed|es|ing|ation)|customiz(e|ed|es|ing)|gray|catalog|dialog|analog|defense|offense|pretense|traveling|canceled|modeled|labeled|enroll|fulfill|installment)\b'

# Inline code spans in Markdown are identifiers and exempt: strip them first.
md_hits=$(for f in $(files | grep -E '\.md$'); do
    sed -E 's/`[^`]*`//g' "$f" | grep -nEi "$AMERICAN" | sed "s|^|$f:|"
done 2>/dev/null)
comment_hits=$(files | grep -vE '\.md$' | xargs -r grep -nEi "^[[:space:]]*(//|#)[^!].*$AMERICAN" 2>/dev/null)
spelling=$(printf '%s\n%s\n' "$md_hits" "$comment_hits" \
    | grep -v '^$' \
    | grep -vE 'SPDX-License-Identifier|LICENSE')

if [ -n "$spelling" ]; then
    printf '\nAmerican spelling in prose. See the table in docs/style.md.\n'
    printf '(Identifiers and API names keep their real spelling and are exempt.)\n'
    printf '%s\n' "$spelling" | sed 's/^/  /'
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "style: clean"
else
    printf '\nstyle: findings above. See docs/style.md.\n'
fi
exit "$fail"
