# ring-buzz

Plays a haptic tick on an MX Master 4 each time the cursor moves onto a
different slot of Droppy's Action Ring, through
`openlogi haptic play tick`.

Droppy is not modified and is not asked for anything. While its ring is open,
Droppy exposes it through macOS accessibility as an `Action Ring` group with
one element per slot. ring-buzz reads those positions when the ring appears,
then picks the slot under the cursor by its distance from the ring's centre
(dead centre, inner ring, outer ring) and its angle. It looks for the ring
only while the pointer moves, at most every 100 ms, so an idle Mac costs
nothing.

## Install

Needs an OpenLogi whose agent has `openlogi haptic play` (agent protocol 47
or later).

```sh
./install.sh
# against a dev build of the agent:
OPENLOGI=/path/to/target/release/openlogi OPENLOGI_PROFILE=dev ./install.sh
./install.sh --uninstall
```

macOS asks once for Accessibility. Grant it in System Settings › Privacy &
Security › Accessibility; the login item retries every 30 s until it can
start.

## Limits

- It follows Droppy's accessibility tree, so a Droppy update that renames the
  `Action Ring` group or stops publishing its slots silences ring-buzz. It
  never affects Droppy itself.
- An empty slot has no element, so crossing it ticks as its nearest
  neighbour.

`./ring-buzz --self-check` runs the slot geometry checks;
`RING_BUZZ_DEBUG=1 ./ring-buzz` logs the ring it finds and each slot change.
