// SPDX-License-Identifier: LGPL-2.1-or-later
#include "goanna_fine.h"
#include "mapblock.h"
#include "goanna_lod_storage.h"
#include "util/base64.h"
#include <sstream>
#include <zlib.h>
namespace goanna {
bool decodeFineBlock(const std::string &wire,const std::string &who,
        const std::function<content_t(const std::string &)> &resolve,FineBlock &out) {
    if(wire.size()>65535) return false;
    std::istringstream in(wire);
    std::string tag,recipient,body,extra;
    int version,x,y,z;
    FineBlock next;
    if(!(in>>tag>>recipient>>version>>next.token>>x>>y>>z>>body) || (in>>extra) ||
            tag!="farfine" || recipient!=who || version!=1 || !next.token ||
            x < -1936 || x > 1936 || y < -1936 || y > 1936 || z < -1936 || z > 1936) return false;
    next.position=v3s16(x,y,z);
    if(body=="-") {out=std::move(next);return true;}
    const auto split=body.find('|');
    if(split==std::string::npos) return false;
    std::vector<content_t> palette{CONTENT_IGNORE};
    std::istringstream names(body.substr(0,split));
    std::string name;
    while(std::getline(names,name,',')) {
        if(name.empty() || name.size()>256 || palette.size()>4096) return false;
        const auto content=resolve(name);
        if(content==CONTENT_IGNORE) return false;
        palette.push_back(content);
    }
    const auto encoded=body.substr(split+1);
    if(!base64_is_valid(encoded)) return false;
    const auto compressed=base64_decode(encoded);
    std::string bytes(4096*6,'\0');
    uLongf size=bytes.size();
    if(uncompress(reinterpret_cast<Bytef*>(bytes.data()),&size,
            reinterpret_cast<const Bytef*>(compressed.data()),compressed.size())!=Z_OK || size%6) return false;
    next.nodes.reserve(4096);
    for(size_t i=0;i<size;i+=6) {
        unsigned count=(uint8_t)bytes[i]*256+(uint8_t)bytes[i+1];
        unsigned index=(uint8_t)bytes[i+2]*256+(uint8_t)bytes[i+3];
        if(!count || !index || index>=palette.size() || next.nodes.size()+count>4096) return false;
        next.nodes.insert(next.nodes.end(),count,MapNode(palette[index],(uint8_t)bytes[i+4],(uint8_t)bytes[i+5]));
    }
    if(next.nodes.size()!=4096) return false;
    next.fingerprint=terrainFingerprint(body);
    next.available=true;out=std::move(next);return true;
}
std::shared_ptr<BlockLodChain> buildFineChain(const FineBlock &source,const NodeDefManager *ndef) {
    if(!source.available || source.nodes.size()!=4096) return {};
    MapBlock block(source.position,nullptr);
    size_t i=0;
    for(int z=0;z<16;++z) for(int y=0;y<16;++y) for(int x=0;x<16;++x)
        block.setNodeNoCheck(x,y,z,source.nodes[i++]);
    auto chain=std::make_shared<BlockLodChain>();
    buildLodChain(ndef,&block,*chain);
    chain->summary=true; // refreshable server data; active near meshes retain ownership
    return chain;
}
}
