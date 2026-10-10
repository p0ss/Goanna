#!/usr/bin/env bash
# Goanna text style and repository rules check. See docs/develop/style.md and
# docs/develop/transplanting.md.
#
# Checks Goanna's own text (not the submodules, not transplanted code),
# tracked files and new files that are not ignored, for:
#   - em dashes and the "--" stand in
#   - smart quotes, ellipsis characters, non breaking spaces
#   - trailing whitespace
#   - common American spellings in prose
# and checks the repository for:
#   - a tracked .uid beside every script, shader and extension under project/
#   - the upstream header, the Goanna note and an inventory row for every
#     file in src/transplant/
#
# It is a gate: it should exit clean on main. The spelling check can still
# flag a legitimate quotation; rewrite the prose or put the quoted name in
# backticks (Markdown) so it reads as an identifier.
#
# Exit status: 0 clean, 1 findings.

set -uo pipefail
case "${1:-}" in -h | --help)
    # Usage is the header comment above.
    awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); if (/^(SPDX|Copyright)/) next
        if (!started && $0 == "") next; started = 1; print }' "$0"
    exit 0 ;;
esac
cd "$(dirname "$0")/.." || exit 2

fail=0

# Goanna's own text only. Excluded:
#   luanti/, godot-cpp/, whisper.cpp/  submodules, not ours
#   src/transplant/      upstream Luanti code, kept byte identical on purpose
#   build/, .godot/      generated
#   LICENSE              the LGPL text, verbatim
#   docs/develop/style.md  has to quote the characters it bans
#   this script          same
EXCLUDES=(':!:luanti/**' ':!:godot-cpp/**' ':!:whisper.cpp/**' ':!:build/**'
          ':!:src/transplant/**'
          ':!:project/.godot/**' ':!:*.import' ':!:LICENSE'
          ':!:docs/develop/style.md' ':!:tools/check-style.sh')
PATTERNS=('*.md' '*.gd' '*.h' '*.cpp' '*.cmake' 'CMakeLists.txt' '*.sh' '*.yml'
          '*.gdextension' '*.godot' '*.py' '*.lua' '*.gdshader' '*.gdshaderinc')

# Tracked files, and new files git would offer to add (not ignored).
listed() {
    git ls-files -- "$@" 2>/dev/null
    git ls-files --others --exclude-standard -- "$@" 2>/dev/null
}

# Extensionless scripts under tools/, known by their shebang.
scripts() {
    listed 'tools/**' "${EXCLUDES[@]}" | grep -vE '(^|/)[^/]*\.[^/]*$' \
        | while IFS= read -r f; do
            [ -f "$f" ] && [ "$(head -c 2 "$f")" = '#!' ] && printf '%s\n' "$f"
        done
}

mapfile -t FILES < <({ listed "${EXCLUDES[@]}" "${PATTERNS[@]}"; scripts; } \
    | sort -u | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done)

files() { printf '%s\n' "${FILES[@]}"; }
is_md() { [[ "$1" == *.md ]]; }
is_lua() { [[ "$1" == *.lua ]]; }

finding() {
    local label="$1" hits="$2"
    if [ -n "$hits" ]; then
        printf '\n%s\n' "$label"
        printf '%s\n' "$hits" | sed 's/^/  /'
        fail=1
    fi
}

report() {
    local label="$1" pattern="$2"
    finding "$label" "$(files | xargs -r -d '\n' grep -nP "$pattern" 2>/dev/null)"
}

# Markdown with inline code spans and fenced blocks blanked, since those
# quote real commands and source. Fenced lines are blanked rather than
# dropped, so line numbers still match.
md_prose() {
    awk '/^[[:space:]]*```/ { fence = !fence; print ""; next } fence { print ""; next } { print }' "$1" \
        | sed -E 's/`[^`]*`//g'
}

report "em dash (U+2014). Use a comma, a full stop, a colon or brackets." \
       '\x{2014}'

# '--' as a dash. In Markdown, code spans and fences are exempt (a command
# line carries a literal "--"). In Lua "--" starts a comment, so only a
# second one inside a comment counts. In both, one ending a line counts too.
dash_hits=$(for f in "${FILES[@]}"; do
    if is_md "$f"; then
        md_prose "$f" | grep -nP '\S\s--(\s\S|\s*$)' | sed "s|^|$f:|"
    elif is_lua "$f"; then
        grep -nP -- '--.*\S\s--(\s\S|\s*$)' "$f" | sed "s|^|$f:|"
    else
        grep -nP '\S\s--\s\S' "$f" | sed "s|^|$f:|"
    fi
done 2>/dev/null)
finding "'--' used as an em dash. Same rule." "$dash_hits"

report "smart quotes or ellipsis. Use straight quotes and full stops." \
       '[\x{2018}\x{2019}\x{201C}\x{201D}\x{2026}]'
report "non breaking or zero width space." \
       '[\x{00A0}\x{200B}\x{FEFF}]'
report "trailing whitespace." \
       ' +$'

# American spellings. Prose only. Markdown is checked in full; code files are
# checked on comment lines alone, because identifiers legitimately carry
# American spelling (Godot's Color, Luanti's getNeighbors, normalize,
# serialize). Within those lines anything shaped like an identifier is
# dropped before matching: a name called as a function (initialize(),
# normalized()), a member or scoped name (Vector3.normalized, Foo::serialize),
# anything in backticks, ALL_CAPS constants and built ins (Godot's COLOR)
# and, in code comments, anything in double quotes (a key, a list name or a
# quoted string). snake_case and camelCase names never match,
# because the list is matched on word boundaries. src/transplant is excluded
# from every check above, because it is upstream Luanti code and must stay
# byte identical apart from the documented changes.
AMERICAN='\b(color|colors|colored|coloring|behavior|behaviors|neighbor|neighbors|center|centers|centered|centering|meters|liter|liters|fiber|organiz(e|ed|es|ing|ation)|recogniz(e|ed|es|ing)|analyz(e|ed|es|ing)|paralyz(e|ed|es|ing)|optimiz(e|ed|es|ing|ation)|customiz(e|ed|es|ing)|initializ(e|ed|es|ing|ation)|serializ(e|ed|es|ing|ation)|deserializ(e|ed|es|ing|ation)|normaliz(e|ed|es|ing|ation)|visualiz(e|ed|es|ing|ation)|minimiz(e|ed|es|ing)|maximiz(e|ed|es|ing)|favor|favors|favored|favoring|favorite|favorites|honor|honors|honored|honoring|armor|armors|armored|gray|catalog|dialog|analog|defense|offense|pretense|traveling|canceled|modeled|labeled|enroll|fulfill|installment)\b'

# Drop identifier shaped words, keep the rest of the line.
strip_identifiers() {
    sed -E -e 's/`[^`]*`//g' \
           -e 's/\b[A-Z][A-Z0-9_]+\b//g' \
           -e 's/[A-Za-z_][A-Za-z0-9_]*\(//g' \
           -e 's/[A-Za-z0-9_]+(\.|::|->)[A-Za-z_][A-Za-z0-9_]*//g' \
           -e 's/(\.|::|->)[A-Za-z_][A-Za-z0-9_]*//g'
}

# Attribution files quote upstream credits verbatim, so they keep the
# spelling their authors used.
md_hits=$(for f in "${FILES[@]}"; do
    is_md "$f" || continue
    case "$f" in */ATTRIBUTION.md|ATTRIBUTION.md) continue ;; esac
    md_prose "$f" | strip_identifiers | grep -nEi "$AMERICAN" | sed "s|^|$f:|"
done 2>/dev/null)

# Comment lines: // and # everywhere (not a #! line or a C preprocessor
# directive), -- in Lua.
comment_hits=$(files | grep -vE '\.md$' | AMERICAN="$AMERICAN" perl -ne '
    BEGIN { $re = qr/$ENV{AMERICAN}/i; }
    chomp;
    my $f = $_;
    open(my $fh, "<", $f) or next;
    my $lead = $f =~ /\.lua$/ ? qr{--} : qr{//|#};
    while (my $line = <$fh>) {
        chomp $line;
        next unless $line =~ /^\s*(?:$lead)/;
        next if $line =~ /^\s*#\s*(?:!|include|define|if|ifdef|ifndef|else|elif|endif|pragma|undef)\b/;
        my $t = $line;
        $t =~ s/`[^`]*`//g;
        $t =~ s/"[^"]*"//g;
        $t =~ s/\b[A-Z][A-Z0-9_]+\b//g;
        $t =~ s/[A-Za-z_][A-Za-z0-9_]*\(//g;
        $t =~ s/[A-Za-z0-9_]+(?:\.|::|->)[A-Za-z_][A-Za-z0-9_]*//g;
        $t =~ s/(?:\.|::|->)[A-Za-z_][A-Za-z0-9_]*//g;
        print "$f:$.:$line\n" if $t =~ $re;
    }
    close $fh;
' 2>/dev/null)

# Formspec element syntax (bgcolor[...], box[...], tooltip[...]) is protocol
# vocabulary with fixed spelling, and it turns up in comments that document
# what a renderer handles. Exempt any line carrying an element signature.
spelling=$(printf '%s\n%s\n' "$md_hits" "$comment_hits" \
    | grep -v '^$' \
    | grep -vE 'SPDX-License-Identifier|LICENSE' \
    | grep -vE '\b[a-z_]+\[[a-z_;,.<>|]*\]')

if [ -n "$spelling" ]; then
    printf '\nAmerican spelling in prose. See the table in docs/develop/style.md.\n'
    printf '(Identifiers and API names keep their real spelling and are exempt.)\n'
    printf '%s\n' "$spelling" | sed 's/^/  /'
    fail=1
fi

# --- repository rules ---------------------------------------------------------

# Godot 4 gives each script, shader and extension a .uid file, and scenes
# refer to the resource by it. A source committed without its .uid gets a
# fresh one on every machine that opens the project, and references made on
# one machine break on the next. A new file that is not yet tracked only
# warns, since its author may not have committed yet.
uid_missing=""
uid_new=""
while IFS= read -r f; do
    [ -f "$f" ] || continue
    if git ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
        if ! git ls-files --error-unmatch -- "$f.uid" >/dev/null 2>&1; then
            if [ -f "$f.uid" ]; then
                uid_missing+="$f (its .uid exists but is not tracked)"$'\n'
            else
                uid_missing+="$f (no .uid; open the project in Godot to make one)"$'\n'
            fi
        fi
    elif [ ! -f "$f.uid" ]; then
        uid_new+="$f"$'\n'
    fi
done < <(listed 'project/**/*.gd' 'project/**/*.gdshader' 'project/**/*.gdshaderinc' \
             'project/**/*.gdextension' 'project/*.gd' 'project/*.gdshader' \
             'project/*.gdshaderinc' 'project/*.gdextension' ':!:project/.godot/**' \
         | sort -u)
finding "tracked Godot source without a tracked .uid. Commit the .uid with it." \
        "${uid_missing%$'\n'}"
if [ -n "$uid_new" ]; then
    printf '\nwarning: new Godot source with no .uid yet (not a failure until tracked).\n'
    printf '%s' "$uid_new" | sed 's/^/  /'
fi

# Every transplanted file starts with upstream's own header (the SPDX line
# and its copyright lines, as Luanti has them) and then a Goanna note saying
# what changed, and has a row in the inventory in docs/develop/transplanting.md.
# Copied code without its upstream copyright is a licence violation.
transplant=$(listed 'src/transplant/**' | sort -u | while IFS= read -r f; do
    [ -f "$f" ] && printf '%s\n' "$f"
done)
if [ -n "$transplant" ]; then
    header_hits=$(printf '%s\n' "$transplant" | while IFS= read -r f; do
        # The leading comment block, up to the first line that is not a
        # // comment.
        problem=$(awk '
            !/^\/\// { exit }
            /SPDX-License-Identifier:/ { if (note) late = 1; spdx = NR }
            /Copyright/ { if (note) late = 1; copy = NR }
            /Goanna/ { if (spdx && copy && !note) note = NR }
            END {
                if (!spdx) print "no SPDX-License-Identifier line at the top"
                else if (!copy) print "no upstream Copyright line at the top"
                else if (!note) print "no Goanna note after the upstream header"
                else if (late) print "the upstream header must come before the Goanna note"
            }' "$f")
        [ -n "$problem" ] && printf '%s: %s\n' "$f" "$problem"
    done)
    finding "transplanted file without its upstream header and Goanna note. See docs/develop/transplanting.md." \
            "$header_hits"

    # Inventory rows name files as `src/transplant/x.h`, `.cpp`: a bare
    # extension repeats the path before it.
    inventory=$(grep -E '^\|[[:space:]]*`src/transplant/' docs/develop/transplanting.md 2>/dev/null \
        | awk -F'|' '{ print $2 }' \
        | grep -oE '`[^`]+`' | tr -d '`' \
        | awk '/^src\/transplant\// { base = $0; sub(/\.[^.\/]*$/, "", base); print; next }
               /^\.[A-Za-z0-9]+$/ && base != "" { print base $0 }')
    missing_rows=$(printf '%s\n' "$transplant" | while IFS= read -r f; do
        printf '%s\n' "$inventory" | grep -qxF -- "$f" || printf '%s\n' "$f"
    done)
    finding "transplanted file with no row in the inventory table in docs/develop/transplanting.md." \
            "$missing_rows"
fi

if [ "$fail" -eq 0 ]; then
    echo "style: clean"
else
    printf '\nstyle: findings above. See docs/develop/style.md.\n'
fi
exit "$fail"
