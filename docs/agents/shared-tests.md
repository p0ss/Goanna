# Shared test service

`tools/goanna-test` owns a durable local queue for clientless probes,
Goanna player tests and rendered checks. A host adapter supplies the game
server and scene leases. The DorfCraft adapter is
`../../DorfCraft/tools/testbed/shared_host.py`; its usage and operational
limits are documented in that repository's `tools/testbed/README.md`.

Offline checks pass. Clientless probes, runaway callback containment, the
dummy-renderer player script and software/GPU captures passed on a shared
Luanti 5.17.0/Mineclonia server using official Godot 4.5.1. Software used
llvmpipe; GPU used the RTX 3090. DorfCraft records the runs under
`reports/release/shared-test-server/`. Concurrent slot capacity remains
unmeasured; keep pool defaults at one. Shader reload is not yet exposed
through the shared worker.

```sh
export GOANNA_TEST_STATE="$(realpath ../../DorfCraft)/.cache/shared-test"
export GODOT_BIN=/path/to/working/godot
tools/goanna-test serve --adapter ../../DorfCraft/tools/testbed/shared_host.py
tools/goanna-test submit --repo ../../DorfCraft --mode player \
    --script ../../DorfCraft/tools/testbed/probes/player.json
tools/goanna-render shared-submit --repo ../../DorfCraft \
    --script ../../DorfCraft/tools/testbed/probes/render.json
tools/goanna-test queue
```

Submissions freeze their inputs and do not launch the supervisor. Use
`GOANNA_TEST_STATE` for a separate state directory. Only one supervisor can
hold a queue's lock. DorfCraft's `skybox.py serve` also reads local host
and runtime configuration; prefer that entry point for its standing host.
The queue survives host-world replacement, records
attempts and cancellation, and stops dispatch after unresolved cleanup or
a limiter refusal. The adapter waits for memory and launch headroom before
starting a server; the machine-wide limiter remains authoritative.

The `player` mode uses Godot's dummy renderer and a private user-data
directory. `software` uses the existing launcher with lavapipe. `gpu` uses
the existing launcher and its GPU lock. Rendered jobs enter through
`goanna-render shared` internally. That worker borrows the host and scene;
it never creates a world or stops the server. It yields on foreign GPU
activity, cleans its scene and puts its job back in the common queue after
a delay. Existing `goanna-render shoot` fixtures keep their current schema
and owned-server lifecycle; they are not silently reinterpreted.

Client scripts have a `steps` array. A step names a player command, optional
arguments, a client index and expected result fields. The constrained
player interface handles the actions. The worker obtains observation
sequence numbers and reads the client's generated token file. Developer
inspection, camera and UI actions are available through a restricted
`control` channel selection. World-global chat commands and arbitrary
GDScript snippets are excluded from this shared path. The `call` command
permits only `set_climate_enabled` with one boolean argument and
`climate_stats` with no arguments. Captures record the field state in their
result and JSON sidecar, alongside the shared generation. DorfCraft
provides `probes/climate.json` and `probes/climate_scene.lua` as a paired
example. These use a constructed scene in its singlenode host; generated
terrain fixtures still need a matching world profile or their own runner.

The host adapter owns server staging, game-specific fixtures, forceloading,
probe execution and cleanup. Resources default to `state:global`; only
reviewed independent tests should declare disjoint resources. Overlay
execution is initially exclusive. Every job records its exact game base
and generation, and a host change invalidates existing leases.

```sh
python3 tools/test_shared_test.py -v
tools/check-style.sh
```

The queue tests use stand-ins for clients and adapters. They check atomic
admission, resource conflicts, multi-player slot accounting, immutable
snapshots, cancellation, crash recovery and client cleanup. They do not
establish rendering correctness or runtime throughput.
