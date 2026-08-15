#include "goanna_client.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

namespace goanna {

String GoannaClient::hello() const {
    return "goanna: extension loaded";
}

String GoannaClient::luanti_version() const {
    // Placeholder until Luanti sources are linked in.
    return "luanti: not linked yet";
}

void GoannaClient::_bind_methods() {
    ClassDB::bind_method(D_METHOD("hello"), &GoannaClient::hello);
    ClassDB::bind_method(D_METHOD("luanti_version"), &GoannaClient::luanti_version);
}

} // namespace goanna
