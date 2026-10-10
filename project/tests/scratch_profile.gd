# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# For the tests that write user://goanna.cfg. Run straight from a checkout,
# user:// is the player's own profile, and those tests replaced it with a
# file holding one or two test settings: the maintainer's settings were
# lost and material updates left off without anyone choosing it (found
# 2026-10-05). They now run only with XDG_DATA_HOME pointed at a scratch
# folder, as tools/test/test-local-play.py and the benchmarks already do:
#
#     XDG_DATA_HOME=$(mktemp -d) godot --headless --path project --script res://tests/<test>.gd
extends RefCounted

static func refuse_real_profile() -> bool:
	if OS.get_environment("XDG_DATA_HOME") != "" or OS.get_name() == "Windows":
		return false
	push_error("This test rewrites user://goanna.cfg. Run it with XDG_DATA_HOME set to a "
		+ "scratch folder, so the player's own settings are left alone.")
	return true
