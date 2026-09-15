// SPDX-License-Identifier: LGPL-2.1-or-later
#pragma once
#include "goanna_lod.h"
#include "mapnode.h"
#include <functional>
namespace goanna {
struct FineBlock {
    v3s16 position;
    uint64_t token=0, fingerprint=0;
    bool available=false;
    std::vector<MapNode> nodes;
};
bool decodeFineBlock(const std::string &wire, const std::string &who,
        const std::function<content_t(const std::string &)> &resolve, FineBlock &out);
std::shared_ptr<BlockLodChain> buildFineChain(const FineBlock &block, const NodeDefManager *ndef);
}
