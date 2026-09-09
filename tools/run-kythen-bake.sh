#!/usr/bin/env bash
# Bake Kythen's own art, in the three tranches its node registration implies.
#
# Kythen builds its nodes from culture data tables rather than literal
# register_node calls, so the source scanner in pbr_community_select.py sees
# almost nothing. The manifests here come from the game's own definition dump
# instead (tools/goanna_nodedef_dump.lua and friends as worldmods, joined
# once), which is also where the classification review's materials come from.
#
# Kythen's media is CC BY-SA 4.0 and its own; nothing here is a community
# redistribution question. GOANNA_KYTHEN overrides the checkout location.
set -uo pipefail
cd "$(dirname "$0")/.."

KYTHEN="${GOANNA_KYTHEN:-$HOME/Documents/Code/Kythen}"
ROOT="${GOANNA_AUDIT_ROOT:-$HOME/.local/share/goanna-pbr-audit}"
COMFY_OUTPUT="${GOANNA_COMFY_OUTPUT:-/run/media/poss/Pockets/stable-diffusion/comfy-output}"
LOG="$ROOT/bakes/kythen.log"
mkdir -p "$ROOT/bakes"

if [ ! -f "$KYTHEN/game.conf" ]; then
    echo "no Kythen game at $KYTHEN" >&2
    exit 2
fi
if ! curl -s -m 5 -o /dev/null http://127.0.0.1:8188/; then
    echo "ComfyUI is not answering on 127.0.0.1:8188, nothing can bake" >&2
    exit 2
fi

run_stage() {
    local name="$1" manifest="$2" count="$3" bump_size="$4" treatment="$5"
    local output="$ROOT/bakes/$name"
    local reuse=()
    mkdir -p "$output"
    if [ -d "$COMFY_OUTPUT/$name" ]; then
        reuse=(--reuse-outputs "$COMFY_OUTPUT/$name")
    fi
    echo "kythen stage: $name ($count candidates)"
    python3 tools/pbr_bake.py \
        --game "$KYTHEN" --out "$output" --run "$name" \
        --nodedefs "pbr_packs/manifests/$manifest.json" \
        --classification-review pbr_packs/classification_reviews/kythen-v1.json \
        --treatment "$treatment" --chord-spec --bump-size "$bump_size" \
        --keep-albedo --no-previews "${reuse[@]}"
    local bake_status=$?
    python3 tools/check-pbr-quality.py \
        --baked "$output" --nodedefs "pbr_packs/manifests/$manifest.json" \
        --sources "$KYTHEN" \
        --classification-review pbr_packs/classification_reviews/kythen-v1.json \
        --json "$output/quality.json"
    local quality_status=$?
    python3 tools/pbr_review_sheet.py \
        --baked "$output" --sources "$KYTHEN" \
        --quality-json "$output/quality.json" \
        --out "$output/review.png" --limit 500 --tile 96
    local review_status=$?
    echo "stage complete: $name bake=$bake_status quality=$quality_status review=$review_status"
    return "$bake_status"
}

{
    date -Is
    failures=0
    run_stage kythen-terrain-v1 kythen-terrain-v1 287 128 terrain || failures=$((failures + 1))
    run_stage kythen-billboard-v1 kythen-billboard-v1 137 256 billboard || failures=$((failures + 1))
    run_stage kythen-items-v1 kythen-items-v1 484 256 item || failures=$((failures + 1))
    echo "kythen queue complete: stage_failures=$failures"
    date -Is
    exit "$failures"
} 2>&1 | tee -a "$LOG"
