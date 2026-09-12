# Lantern light cast into the room

The concern is illumination of the room, not the brightness of the lantern texture. The earlier emission-only diagnostic intentionally disabled point lights and did not answer that concern.

[Controlled comparisons](index.html).

Inside the room, all four ceiling lanterns are active. Switching only those four lights off substantially darkens the ceiling and upper walls. The torches, camera, exposure and material appearance remain unchanged in this pair. The lanterns' own visible emission remains enabled in both images.

From the village camera outside, the 16-lamp direct-light budget admits none of those four lanterns. Raising the budget to 32 admits all four and restores room illumination visible through the windows and roof opening. This identifies a regression from coupling point-light admission to the shadow budget. It is not an emission-mask problem. The JSON files record actual admitted light positions, energy and shadow state.

The 32-slot image is a diagnostic setting change, not a new committed default or a complete fix. A distance-ranked finite pool can drop visible room lights as the camera moves; its selection and fallback still need work. The production default remains 16. The temporary 3x lantern-energy experiment was rejected and was not applied to code.

The room on/off pair freezes the scene. The outdoor budget pair uses the same camera and time but allows the renderer to update for each budget; it is evidence of lamp admission, not a fully locked landscape comparison. The isolated review world and its settings are used throughout.
