#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Talk to Goanna's player agent channel (docs/agent-interfaces.md).

Shared by tools/goanna-player (the command line) and tools/goanna-player-mcp
(the MCP server). The channel listens on loopback only and wants, in every
request, the token the client writes at launch to
user://player_agent_<port>.token. That file is found here the way Godot
names user:// for a project called Goanna, or taken from:

  GOANNA_PLAYER_AGENT_TOKEN       the token itself
  GOANNA_PLAYER_AGENT_TOKEN_FILE  the file to read it from
  GOANNA_PLAYER_AGENT_HOST/PORT   where the channel is (127.0.0.1:30850)
"""

import json
import os
import pathlib
import socket
import sys

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 30850
# Long enough for the longest action: a 30 second hold, then its settle.
TIMEOUT = 45.0


def user_dir():
    """Godot's user:// for a project named Goanna with no custom directory."""
    if sys.platform.startswith("win"):
        base = pathlib.Path(os.environ.get("APPDATA", pathlib.Path.home() / "AppData" / "Roaming"))
        return base / "Godot" / "app_userdata" / "Goanna"
    if sys.platform == "darwin":
        return pathlib.Path.home() / "Library" / "Application Support" / "Godot" / "app_userdata" / "Goanna"
    base = os.environ.get("XDG_DATA_HOME") or str(pathlib.Path.home() / ".local" / "share")
    return pathlib.Path(base) / "godot" / "app_userdata" / "Goanna"


def token_path(port, override=None):
    path = override or os.environ.get("GOANNA_PLAYER_AGENT_TOKEN_FILE")
    return pathlib.Path(path) if path else user_dir() / ("player_agent_%d.token" % port)


def read_token(port, override=None):
    if os.environ.get("GOANNA_PLAYER_AGENT_TOKEN"):
        return os.environ["GOANNA_PLAYER_AGENT_TOKEN"].strip()
    path = token_path(port, override)
    try:
        return path.read_text().strip()
    except OSError as error:
        raise RuntimeError("cannot read the player agent token at %s (%s). Is the client "
                           "running with GOANNA_PLAYER_AGENT set? If its user data is "
                           "elsewhere, set GOANNA_PLAYER_AGENT_TOKEN_FILE."
                           % (path, error.strerror or error))


def endpoint():
    return (os.environ.get("GOANNA_PLAYER_AGENT_HOST", DEFAULT_HOST),
            int(os.environ.get("GOANNA_PLAYER_AGENT_PORT", DEFAULT_PORT)))


def query(command, args=None, host=None, port=None, token_file=None):
    """Send one request and return its result; raise RuntimeError on a
    transport or protocol error. A refused or stale action is a result, not
    an error."""
    env_host, env_port = endpoint()
    host = host or env_host
    port = int(port or env_port)
    request = {"id": 1, "cmd": command, "args": args or {},
               "token": read_token(port, token_file)}
    try:
        with socket.create_connection((host, port), timeout=TIMEOUT) as peer:
            peer.sendall((json.dumps(request) + "\n").encode())
            data = b""
            while b"\n" not in data:
                chunk = peer.recv(65536)
                if not chunk:
                    raise RuntimeError("endpoint closed without replying")
                data += chunk
    except OSError as error:
        raise RuntimeError("cannot reach the player agent channel on %s:%d: %s"
                           % (host, port, error))
    reply = json.loads(data.split(b"\n", 1)[0], strict=False)
    if not reply.get("ok"):
        raise RuntimeError(reply.get("error", "request failed"))
    return reply["result"]
