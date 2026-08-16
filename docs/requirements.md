# System requirements

Short version: a desktop or laptop with a discrete graphics card from about
2019 onwards. Goanna is a visuals-first client and it asks for more than the
vanilla Luanti client does, deliberately.

If your machine cannot run it, that is not a bug to be fixed later. Run the
vanilla client, which is faster, runs nearly anywhere, and is always the
reference. See `PLAN.md` for why the project made that choice.

## What is actually required

| | |
| --- | --- |
| Graphics | A GPU with a working Vulkan driver, and enough throughput for real-time global illumination. In practice a discrete card. |
| Graphics memory | 3 GB or more, dedicated. Measured use was about 2.4 GB. |
| System memory | 4 GB free for the client. Measured use was about 750 MB, but the Godot editor and a local server want their own. |
| Processor | Any modern x86-64. One core is doing most of the work. |
| Operating system | Linux. A Windows build is wired up but has never been run, let alone played. macOS untried. See `docs/building.md`. |
| Disk | About 2 GB for a built checkout, more if you keep the build tree. |

There is no Compatibility or Mobile renderer path, on purpose. Forward+ and
Vulkan only.

## Measured, not guessed

These numbers come from one machine, so treat them as a single data point
rather than a matrix. Anyone who runs Goanna on different hardware and
reports back is doing the project a real favour.

Measured on 16 August 2026: NVIDIA RTX 3090, AMD Ryzen 7 7800X3D, at
1600x900, connected to a local Mineclonia server, with about 1300 mapblocks
received and 685 meshed.

| | Average | Peak |
| --- | --- | --- |
| Graphics memory, above idle | 1.6 GB | 2.4 GB |
| Graphics utilisation | 62 % | 99 % |
| System memory | 694 MB | 757 MB |
| Processor | 84 % of one core | 99 % |

Two caveats, both of which mean a shipped build should do better. The build
measured was `template_debug` with `RelWithDebInfo`, so Godot's debug checks
were on and the code was not fully optimised. And no frame rate was captured,
so "62 % of an RTX 3090" says the renderer is working hard but does not yet
say at what frame rate.

That figure is still the headline. Sixty-two per cent of a high end card, at
a modest resolution, is a lot, and it is what SDFGI, SSAO, SSIL, volumetric
fog and real shadows cost. Turning those off would change the numbers
completely, and would also remove the reason Goanna exists.

## Will it run on a Raspberry Pi 5?

No, and not narrowly.

The interesting part is that the obvious objection is wrong. A Pi 5 does
have Vulkan: its VideoCore VII runs Mesa's v3dv driver, which reached
Vulkan 1.3 conformance in Mesa 24.3. So the API is there, and Godot's
Forward+ renderer will not refuse to start on the grounds of a missing
Vulkan version.

It fails on throughput instead, by a wide margin:

- Goanna keeps a high end desktop GPU busy 62 per cent of the time at
  1600x900. The Pi 5's integrated graphics are far below that class, and the
  gap is orders of magnitude rather than a generation or two.
- SDFGI is the specific problem. It is a real-time voxel global illumination
  technique, it is the most expensive thing on the frame, and it is the
  single feature Goanna exists to use.
- There is no low specification fallback to drop back to, by design. Turning
  the effects off until a Pi 5 copes would leave you with a slower, less
  complete version of the vanilla client.

There is also a plain practical blocker: no ARM64 build exists. The build
system now derives the architecture correctly, so an `arm64` binary is
possible, but none has been produced or tested, and the `.gdextension` file
lists only x86-64 libraries.

The good news is that the vanilla Luanti client runs well on a Pi 5, plays
every game, connects to every server, and is actively maintained. That is
genuinely the right answer for that hardware, and it is the answer `PLAN.md`
committed to from the start.

## What would move the needle

If you want Goanna to run on weaker hardware, the useful work is not a
fallback renderer. It is making the expensive features optional at run time
so a player can trade quality for frame rate: SDFGI off, shadow distance
down, SSIL off, fog simplified. None of that exists yet. There is currently
no settings screen at all.
