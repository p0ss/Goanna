// SPDX-License-Identifier: LGPL-2.1-or-later
#include "goanna_client.h"
#include "goanna_session.h"
#include "goanna_fine.h"
#include "nodedef.h"
#include <algorithm>
#include <sstream>
using namespace godot;
using namespace goanna;

bool GoannaClient::fineOffered() const {
    if (!m_session || m_lod_distance<=0 || m_session->farRenderingGrant()<=0) return false;
    const auto options=m_session->serverOptions();
    const auto it=options.find("far_fine");
    return it!=options.end() && it->second=="1";
}
void GoannaClient::fineClear() {
    m_fine_states.clear();m_fine_pending.clear();m_fine_scan={};
    m_fine_cursor=v3s16(-32768,-32768,-32768);
    m_fine_ready_sample=m_fine_scan_ready=m_fine_scan_entries=0;m_ms_fine_scan=0;
}

// Called under the map lock alongside ordinary summary consumption.
void GoannaClient::fineUpdate() {
    if (!fineOffered()) return;
    const auto now=std::chrono::steady_clock::now();
    for (const auto &wire:m_session->takeFineBlocks()) {
        if (wire.compare(0,16,"farfine_changed ")==0) {
            std::istringstream in(wire.substr(16));
            int x,y,z;
            if (!(in>>x>>y>>z) || x < -1936 || x > 1936 || y < -1936 || y > 1936 || z < -1936 || z > 1936) continue;
            auto it=m_fine_states.find(v3s16(x,y,z));
            if (it!=m_fine_states.end()) {
                it->second.token=++m_fine_serial;
                it->second.pending=false;it->second.asked={};
                m_fine_pending.erase(it->first);
                auto load=m_lod_loads.find(it->first);
                if (load!=m_lod_loads.end() && load->second.fine_token) m_lod_loads.erase(load);
            }
            continue;
        }
        auto source=std::make_shared<FineBlock>();
        if (!decodeFineBlock(wire,m_session->playerName(),[&](const std::string &name) {
                content_t id=CONTENT_IGNORE;m_session->nodeDefs()->getId(name,id);return id;
            },*source)) continue;
        const auto bp=source->position;
        auto it=m_fine_states.find(bp);
        if (it==m_fine_states.end() || !it->second.pending || it->second.token!=source->token) continue;
        it->second.pending=false;
        m_fine_pending.erase(bp);
        if (!source->available || m_near_blocks.count(bp)) continue;
        if (m_session->blockRevision(bp)!=it->second.node_revision) {it->second.asked={};continue;}
        // Polling is for changed blocks: an identical reply must not rebuild
        // thousands of unchanged regions or restart their surface handoffs.
        auto current=m_lod_chains.find(bp);
        if (current!=m_lod_chains.end() && it->second.fingerprint==source->fingerprint &&
                it->second.applied.lock()==current->second) continue;
        const uint64_t ticket=++m_lod_load_ticket;
        const auto *ndef=m_session->nodeDefs();
        if (m_lod_storage.request(bp,ticket,0,[source,ndef] {return buildFineChain(*source,ndef);})) {
            m_lod_loads[bp]={ticket,m_session->blockRevision(bp),source->token,source->fingerprint};
            m_far_blocks.insert(bp);
        } else it->second.asked={};
    }
    // Timeouts visit only the bounded in-flight set, never the entire world.
    for (auto it=m_fine_pending.begin();it!=m_fine_pending.end();) {
        auto state=m_fine_states.find(*it);
        if (state==m_fine_states.end() ||
                std::chrono::duration<double>(now-state->second.asked).count()>10) {
            if (state!=m_fine_states.end()) state->second.pending=false;
            it=m_fine_pending.erase(it);
        } else ++it;
    }
    if (std::chrono::duration<double>(now-m_fine_scan).count()<0.25) return;
    const auto scan_start=std::chrono::steady_clock::now();
    m_fine_scan_entries=0;
    const int radius=std::min(m_far_distance,m_session->farRenderingGrant());
    struct Due {bool refresh;float distance;std::chrono::steady_clock::time_point asked;v3s16 position;};
    std::vector<Due> due;
    // A large ordinary world can have hundreds of thousands of candidates.
    // Resume a bounded slice on the next frame; a full scan formerly took
    // hundreds of milliseconds and ran again as soon as that frame ended.
    auto it=m_fine_states.lower_bound(m_fine_cursor);
    while (it!=m_fine_states.end() && m_fine_scan_entries<512 &&
            std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-scan_start).count()<1.0) {
        ++m_fine_scan_entries;
        const auto bp=it->first;
        auto &state=it->second;
        const float dx=bp.X*16+8-m_lod_centre.x, dz=-bp.Z*16-8-m_lod_centre.z;
        const float dy=bp.Y*16+8-m_lod_centre.y;
        const float distance=std::sqrt(dx*dx+dz*dz);
        if (distance>radius+32 || std::abs(dy)>radius+32) {
            m_fine_pending.erase(bp);it=m_fine_states.erase(it);continue;
        }
        ++it;
        const double age=std::chrono::duration<double>(now-state.asked).count();
        auto chain=m_lod_chains.find(bp);
        const bool fine=chain!=m_lod_chains.end() && chain->second->hasCell(1);
        m_fine_scan_ready+=fine;
        if (state.pending || m_near_blocks.count(bp) || m_lod_loads.count(bp)) continue;
        if (!fine && lodTierFor(bp,m_lod_centre,false)>=3) continue;
        if (state.token && age<30) continue; // refresh also observes bulk/ABM edits
        due.push_back({fine,distance,state.asked,bp});
    }
    if (it==m_fine_states.end()) {
        m_fine_cursor=v3s16(-32768,-32768,-32768);
        m_fine_ready_sample=m_fine_scan_ready;m_fine_scan_ready=0;
        m_fine_scan=now;
    } else m_fine_cursor=it->first;
    std::sort(due.begin(),due.end(),[](const auto &a,const auto &b){
        if (a.refresh!=b.refresh) return a.refresh<b.refresh;
        if (a.refresh && a.asked!=b.asked) return a.asked<b.asked;
        return a.distance<b.distance;
    });
    for (const auto &item:due) {
        if (m_fine_pending.size()>=16) break;
        auto &state=m_fine_states[item.position];
        state.pending=true;state.asked=now;state.token=++m_fine_serial;
        state.node_revision=m_session->blockRevision(item.position);
        m_session->requestFineBlock(item.position,state.token);
        m_fine_pending.insert(item.position);
    }
    m_ms_fine_scan=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-scan_start).count();
}
