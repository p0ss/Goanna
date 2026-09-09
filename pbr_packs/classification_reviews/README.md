# PBR classification reviews

These versioned files are the reviewed material intent consumed by
`tools/pbr_bake.py --classification-review`. They sit between mechanical
texture discovery and generative baking so filename guesses are not the final
authority for composite or ambiguous art.

Each file contains a `schema_version`, a `review_version`, and a `textures`
object keyed by texture stem. A texture record may override:

- `primary_material`: the prompt and physical baseline;
- `secondary_materials`: materials visibly sharing the image;
- `metalness_policy`: `none`, `partial`, or `predominant`;
- `smoothness_min` and `smoothness_max`: permitted perceptual smoothness;
- `relief_strength`: the fraction of the height byte range available to relief;
- `treatment`: `terrain`, `item`, `billboard`, `model_skin`, or `gui`;
- `tiles`: whether opposite image edges are expected to meet;
- `confidence`, `rationale`, and `review_required`: review provenance.

Large homogeneous families may instead use an ordered `rules` array with
shell-style `match` patterns and an `entries` object for exact exceptions.
Later matching rules refine earlier ones; exact entries always win.

Low-confidence records remain useful for queue triage, but a release bundle
must not silently treat them as approved.
