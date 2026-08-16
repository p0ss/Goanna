// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2010-2013 celeron55, Perttu Ahola <celeron55@gmail.com>
//
// Copied verbatim from luanti/src/inventorymanager.cpp against Luanti
// 5.16.1, 2026-08. Small pieces of Luanti that live in server-only
// translation units but are referenced by the shared core Goanna links.
// Copied so that file, which drags in the server environment and scripting,
// need not be compiled.

#include <sstream>

#include "exceptions.h"
#include "inventorymanager.h"
#include "log.h"
#include "util/strfnd.h"

void InventoryLocation::deSerialize(std::istream &is)
{
	std::string tname;
	std::getline(is, tname, ':');
	if (tname == "undefined") {
		type = InventoryLocation::UNDEFINED;
	} else if (tname == "current_player") {
		type = InventoryLocation::CURRENT_PLAYER;
	} else if (tname == "player") {
		type = InventoryLocation::PLAYER;
		std::getline(is, name, '\n');
	} else if (tname == "nodemeta") {
		type = InventoryLocation::NODEMETA;
		std::string pos;
		std::getline(is, pos, '\n');
		Strfnd fn(pos);
		p.X = stoi(fn.next(","));
		p.Y = stoi(fn.next(","));
		p.Z = stoi(fn.next(","));
	} else if (tname == "detached") {
		type = InventoryLocation::DETACHED;
		std::getline(is, name, '\n');
	} else {
		infostream<<"Unknown InventoryLocation type=\""<<tname<<"\""<<std::endl;
		throw SerializationError("Unknown InventoryLocation type");
	}
}

void InventoryLocation::deSerialize(const std::string &s)
{
	std::istringstream is(s, std::ios::binary);
	deSerialize(is);
}
