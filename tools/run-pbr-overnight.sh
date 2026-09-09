#!/usr/bin/env bash
# Resume-safe, licence-cleared terrain bake followed by QA artefacts.
#
# The staging root holds the extracted source packages and every baked map.
# It must not be /tmp: that is tmpfs on the development box, so a reboot took
# a whole night's bake and the sources with it. Override with
# GOANNA_AUDIT_ROOT if the default filesystem is short of space.
set -uo pipefail
cd "$(dirname "$0")/.."

ROOT="${GOANNA_AUDIT_ROOT:-$HOME/.local/share/goanna-pbr-audit}"
# ComfyUI keeps every image it generated, on ordinary disk, so a stage whose
# composed maps were lost can be rebuilt from them without paying the GPU
# again. Each stage reuses only its own run folder, which is the only place
# the settings are known to match.
COMFY_OUTPUT="${GOANNA_COMFY_OUTPUT:-/run/media/poss/Pockets/stable-diffusion/comfy-output}"
LOG="$ROOT/bakes/full-map-v2.log"
mkdir -p "$ROOT/bakes"

if ! curl -s -m 5 -o /dev/null http://127.0.0.1:8188/; then
    echo "ComfyUI is not answering on 127.0.0.1:8188, nothing can bake" >&2
    exit 2
fi

python3 tools/pbr_stage_sources.py --dest "$ROOT/src" \
    animalia glass_stained mesecons moreblocks naturalbiomes nether \
    stainedglass || exit 2
python3 tools/pbr_stage_sources.py --dest "$ROOT/top-blocks/src" \
    too_many_stones || exit 2
python3 tools/pbr_stage_sources.py --dest "$ROOT/game-intake/src" \
    backroomtest pmb_core || exit 2

run_stage() {
    local name="$1" source="$2" manifest="$3" review="$4" count="$5"
    local bump_size="${6:-128}" treatment="${7:-terrain}"
    local output="$ROOT/bakes/$name"
    local reuse=()
    mkdir -p "$output"
    if [ -d "$COMFY_OUTPUT/$name" ]; then
        reuse=(--reuse-outputs "$COMFY_OUTPUT/$name")
    fi
    echo "overnight stage: $name ($count candidates)"
    python3 tools/pbr_bake.py \
        --game "$source" --out "$output" --run "$name" \
        --nodedefs "$manifest" --classification-review "$review" \
        --treatment "$treatment" --chord-spec --bump-size "$bump_size" \
        --keep-albedo --no-previews "${reuse[@]}"
    local bake_status=$?
    python3 tools/check-pbr-quality.py \
        --baked "$output" --nodedefs "$manifest" --sources "$source" \
        --classification-review "$review" \
        --json "$output/quality.json"
    local quality_status=$?
    python3 tools/pbr_review_sheet.py \
        --baked "$output" --sources "$source" \
        --quality-json "$output/quality.json" \
        --out "$output/review.png" --limit 500 --tile 96
    local review_status=$?
    echo "stage complete: $name bake=$bake_status quality=$quality_status review=$review_status"
    return "$bake_status"
}

{
    date -Is
    failures=0
    run_stage too-many-stones-terrain-v2 \
        "$ROOT/top-blocks/src/too_many_stones" \
        pbr_packs/manifests/too-many-stones-terrain-v2.json \
        pbr_packs/classification_reviews/terrain-v1.json 397 128 terrain || failures=$((failures + 1))
    run_stage community-cleared-terrain-v2 \
        "$ROOT/src" \
        pbr_packs/manifests/community-terrain-v2.json \
        pbr_packs/classification_reviews/terrain-v1.json 205 128 terrain || failures=$((failures + 1))
    run_stage backrooms-test-terrain-v1 \
        "$ROOT/game-intake/src/backroomtest" \
        pbr_packs/manifests/backrooms-test-terrain-v1.json \
        pbr_packs/classification_reviews/accepted-games-terrain-v1.json 6 128 terrain || failures=$((failures + 1))
    run_stage age-of-mending-terrain-v1 \
        "$ROOT/game-intake/src/pmb_core" \
        pbr_packs/manifests/age-of-mending-terrain-v1.json \
        pbr_packs/classification_reviews/accepted-games-terrain-v1.json 138 128 terrain || failures=$((failures + 1))
    run_stage community-cleared-billboard-v2 \
        "$ROOT/src" \
        pbr_packs/manifests/community-billboard-v2.json \
        pbr_packs/classification_reviews/billboards-v1.json 72 256 billboard || failures=$((failures + 1))
    run_stage backroomtest-billboards-v1 \
        "$ROOT/game-intake/src/backroomtest" \
        pbr_packs/manifests/backroomtest-billboards-v1.json \
        pbr_packs/classification_reviews/backroomtest-billboards-v1.json 1 256 billboard || failures=$((failures + 1))
    run_stage pmb-core-billboards-v1 \
        "$ROOT/game-intake/src/pmb_core" \
        pbr_packs/manifests/pmb-core-billboards-v1.json \
        pbr_packs/classification_reviews/pmb-core-billboards-v1.json 11 256 billboard || failures=$((failures + 1))
    run_stage backroomtest-items-v1 \
        "$ROOT/game-intake/src/backroomtest" \
        pbr_packs/manifests/backroomtest-items-v1.json \
        pbr_packs/classification_reviews/backroomtest-items-v1.json 23 256 item || failures=$((failures + 1))
    run_stage pmb-core-items-v1 \
        "$ROOT/game-intake/src/pmb_core" \
        pbr_packs/manifests/pmb-core-items-v1.json \
        pbr_packs/classification_reviews/pmb-core-items-v1.json 90 256 item || failures=$((failures + 1))
    echo "overnight queue complete: stage_failures=$failures"
    date -Is
    exit "$failures"
} 2>&1 | tee -a "$LOG"
