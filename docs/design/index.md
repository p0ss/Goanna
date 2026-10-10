# Design

Plans, proposals and the reasoning behind decisions. A design page says
what was intended and why; how the code works now is under
[systems](../systems/index.md), and what actually happened is under
[history](../history/index.md).

## Direction

- [The founding plan](plan.md): the decisions Goanna was started on, why
  the approach is feasible, the compatibility ladder and the risks.
- [Roadmap](roadmap.md): current priorities and engineering constraints.

## Rendering

- [Far rendering plan](far-rendering-plan.md): the August 2026 plan for
  a vista to the horizon and the order of work it set.
- [Materials and shading](pbr-plan.md): the material pipeline's design and
  remaining work.
- [A material format for Luanti](material-format.md): LabPBR against glTF
  2.0, and a proposed shape for material data a game could ship.
- [Iris shader packs](iris-compat.md): the plan for loading Iris and
  OptiFine shader packs.

## Servers and boundaries

- [Capabilities](capabilities.md): what Godot unlocks, what needs a
  server's authorisation, and in what order.
- [Validating capabilities](validation.md): what a server side validator
  would have to do, and why it is not anticheat.
- [Director design](director-design.md): the design of the AI game master.
- [Freeminer servers](freeminer-plan.md): findings and a plan for joining
  Freeminer servers.
