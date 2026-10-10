// SPDX-License-Identifier: LGPL-2.1-or-later
// Fine node data: the real nodes of a far block, sent by the server mod's
// fine.lua on request (a `farfine` reply on the goanna:v1 channel), for
// blocks close enough to draw at cell 1 or 2 but outside the server's own
// send range. A summary gives only coarse cells; this gives the same 4096
// nodes a MapBlock holds, so the detailed far tiers keep thin trunks and
// overhangs.
//
// Threads: decodeFineBlock runs on Godot's main thread, in
// GoannaClient::fineUpdate (goanna_client_fine.cpp); buildFineChain runs on
// the LodStorage worker, through the LiveBuild that fineUpdate hands it. Both
// work on plain values and touch neither Godot nor the session's map.
//
// Main types: FineBlock.
#pragma once
#include "goanna_lod.h"
#include "mapnode.h"
#include <functional>
namespace goanna {
// One decoded reply. `token` echoes the request, so a reply to a superseded
// request is ignored; `available` is false when the server could not read the
// block (unloaded or ungenerated), which is never treated as air.
struct FineBlock {
    v3s16 position;
    uint64_t token=0, fingerprint=0;
    bool available=false;
    std::vector<MapNode> nodes;
};
// Validates every bound before allocating, since the bytes come off the
// network, and accepts only a reply addressed to `who`. `resolve` maps a node
// name to this session's content id.
bool decodeFineBlock(const std::string &wire, const std::string &who,
        const std::function<content_t(const std::string &)> &resolve, FineBlock &out);
// The block's LOD chain, marked as a summary so a later reply can replace it
// while a live block's chain never is.
std::shared_ptr<BlockLodChain> buildFineChain(const FineBlock &block, const NodeDefManager *ndef);
}
