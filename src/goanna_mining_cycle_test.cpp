// SPDX-License-Identifier: LGPL-2.1-or-later
#include "goanna_mining_cycle.h"
#include "goanna_radial_form.h"
#include <cstdio>
#include <vector>
int main() {
    int failures=0;
    auto check=[&](bool ok,const char *message) { if(!ok){++failures; std::printf("FAIL %s\n",message);} };
    for (double duration : {0.0,.1,.4,1.333,3.0,20.0}) {
        std::vector<bool> reference;
        for (int fps : {15,60,240}) {
            goanna::MiningCycle cycle;
            cycle.reset(duration);
            goanna::FormDig dig;
            dig.beginCube();
            const auto cube_solid = [](float, float, float) { return true; };
            int contacts=0;
            double time=0;
            while (!cycle.complete()) {
                auto before=goanna::formGridDamaged(cube_solid, dig.baseline, dig.damage, 16);
                bool contact=cycle.advance(1.0/fps);
                time+=1.0/fps;
                if (contact) {
                    ++contacts;
                    check(cycle.pose(true)==1,"contact is the end of the downstroke");
                    check(dig.advance(cycle.progress(),.2f,.5f,.13f,0.f,1.f,0.f),"every blow advances deformation");
                } else {
                    check(before==goanna::formGridDamaged(cube_solid, dig.baseline, dig.damage, 16),"no deformation during wind-up");
                }
                check(cycle.pose(contact)>=0 && cycle.pose(contact)<=1,"bounded hand pose");
            }
            check(contacts==cycle.blows,"one contact per stroke at each frame rate");
            check(time+1e-6>=duration,"never completes before server tool time");
            check(time<std::max(.24,duration)+1.0/fps+1e-5,"no extra final swing delay");
            auto result=goanna::formGridDamaged(cube_solid, dig.baseline, dig.damage, 16);
            if(reference.empty()) reference=result;
            check(result==reference,"frame rate cannot change the final deformation");
        }
    }
    goanna::MiningCycle stone;
    stone.reset(1.333, 8);
    check(stone.blows==8 && std::abs(stone.period-goanna::kSwingPeriod)<1e-6,"stone keeps eight deliberate chips rather than two destructive blows");
    stone.advance(1.333);
    check(!stone.complete() && stone.progress()<1.0f,"the old whole-block timer cannot force early destruction");
    goanna::MiningCycle stalled;
    stalled.reset(3);
    check(stalled.advance(2),"a stalled frame catches up contact");
    check(stalled.landed>1 && stalled.landed==(int)std::floor(2/stalled.period+goanna::kSwingLead),"missed contacts retain accumulated damage");
    check(!stalled.advance(0),"contact is not replayed without time advancing");
    stalled.reset(1);
    check(stalled.landed==0 && stalled.elapsed==0,"new target discards the previous cycle");
    check(!stalled.advance(.1),"new target does not inherit a pending contact");
    goanna::MiningCycle first;
    first.reset(1);
    const float at_start=first.pose(false);
    first.advance(.02);
    check(first.pose(false)>at_start,"the first motion is the downstroke, not a wind-up");
    std::printf("Mining cycle: %d failures\n",failures);
    return failures?1:0;
}
