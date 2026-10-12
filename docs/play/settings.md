# Settings

Settings opens from the main menu and from the pause menu in a game. Most
options take effect at once.

## Graphics quality

The graphics quality profile picks one of five tiers, Lowest, Low, Medium, High
and Ultra, each a set of distances, cloud styles, lighting features and texture
resolution sized for a class of machine, from a Steam Deck class handheld to a
powerful desktop. Changing any single option afterwards shows the profile as
Custom. The tiers are candidates: their hardware roles are intent, not measured
compatibility. What each sets is in [graphics
tiers](../systems/graphics-tiers.md), and what hardware Goanna wants is in
[system requirements](requirements.md).

## Interface style

Settings, Appearance, Interface style chooses how menus and game forms look.
It takes effect at once, in the main menu or in game.

- Dark glass, the default, draws Goanna's menus, chat, the hotbar and every
  game form (inventories, chests, furnaces and the rest) on dark translucent
  panels that blur the world behind them. The game's own pictures are kept:
  items, the empty armour slot outlines, progress arrows, player models,
  books and any screen a game draws with its own art. Only the plain window
  parts, the grey panels, slot squares, tab and button frames, are
  replaced; a tab keeps the game's icon, and the selected one is ringed.
  Dark text a game chose for its light panels is lightened so it can be read
  on the dark glass.
- Game theme draws every form in the game's own window art, as the game's
  authors made it and as Luanti's own client shows it, and Goanna's menus as
  they were before the glass.

Neither choice changes what a form does or sends to the server. Details, and
what is not handled yet, are in
[interface style](../systems/interface-style.md).

## Rendering options

Goanna's important visual systems are adjustable while connected:

- View and far distance control how much live and remembered terrain is drawn.
- Terrain occlusion removes regions hidden behind opaque nearby geometry.
- Material settings control normals, roughness, specular, emission, bevels and
  surface detail.
- Lighting settings control SDFGI, ambient light, lamps, shadows and shafts.
  With lamp shadows enabled, their budget also limits direct lamp count so
  excess lamps cannot shine through walls. Distant lighting uses propagated
  block light. Zero shadow-casting lamps explicitly disables lamp shadows.
- The Appearance tab has Natural look, Night visibility and Bloom controls.
  Natural look adds depth in high daylight; night, dawn and sunset keep their
  existing grade. Night visibility defaults to 0.5 and adds a faint blue
  upper sky, supplying cool ambient and bounced light through the existing
  lighting system. It leaves the horizon colour and night grade unchanged;
  zero restores the original sky. These preferences are independent of the
  graphics quality profile.
- Volumetric atmosphere controls the local valley-mist volume; set it to zero
  to disable that froxel cost on slower hardware. The raymarched cumulus
  stay in the sky pass and share the terrain's sun, twilight and
  horizon-haze colours.

Terrain that has not arrived from the server cannot be reconstructed by a
normal client. Goanna can display remembered blocks and server-provided coarse
summaries when the server grants its far-rendering capability; otherwise the
horizon is limited by the server's send and generation distance.

## Procedural grass

Settings, Graphics, Procedural grass draws grass blades on grass topped
ground that bend round players and in the wind. It is off by default, off at
Lowest and Low, and on at Medium and above, with density, draw distance and
interaction settings of its own. It changes nothing on the server. How it
works is in [procedural grass](../systems/procedural-grass.md).

## Shader packs

Settings, Graphics, Shader pack runs an Iris or OptiFine shader pack, the
kind made for Minecraft, in place of Goanna's own look. Only part of what
packs do is supported so far, so most packs look different from their
screenshots and some will not load at all; what each popular pack does is
in [shader pack status](../develop/shaderpack-status.md).

Packs go in the shader pack folder, which the row shows as text with an
Open folder button beside it. On Linux it is
`~/.local/share/godot/app_userdata/Goanna/shaderpacks`. Put a pack there
as it was downloaded from Modrinth or CurseForge, still zipped, or unzipped
as a folder holding `shaders/`. A zip is unpacked once, the first time it
is used, into `shaderpack_cache` beside the folder, and again only if the
zip is replaced. Look again lists the folder afresh after adding a pack.

The picker offers Off and every pack in the folder by name. Under it, Pack
options lists the selected pack's switches and lists of values, under the
pack's own headings and names, as Iris shows them; Pack defaults forgets
every change made to that pack. Options that are numbers written into the
pack's code, and option profiles, are not offered yet. Each pack keeps its
own options.

A pack, and any option, applies the next time you join a world: a world
that is already open keeps what it started with. After a join the row
says in one line how the pack did, for example how many of its screen
passes compiled, whether its own terrain and water shading is in use, or
why it did not load.
