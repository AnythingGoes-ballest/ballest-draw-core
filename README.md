# Draw Core

A library plugin for the [Ballest plugin manager](https://github.com/AnythingGoes-ballest/ballest-plugin-manager): the
drawing that [Inspect Draw](../ballest-inspect-draw) and [Draw Track](../ballest-draw-track) share. It has no menu of
its own; it is installed with them.

What it does for a plugin that imports it (`dependencies = ["draw-core"]`):

- turns the left mouse button and the cursor into a stroke: points sampled every 4 pixels along the cursor's path,
  placed on the surfaces under it (keeping to the surface the stroke started on, bridging gaps at the line's depth), on
  a level plane, or in the air;
- shows a see-through layer while a tool is on, so the game's camera or the editor doesn't take the clicks;
- shows a ring at the cursor the size of the brush.

```angelscript
import void DrawCore_Frame(bool enabled, bool capture, bool overYourWindow, int placement, double planeHeight,
                           double brushRadius, double pointSpacing, double airDistance, double ringPixels) from "draw-core";
import int DrawCore_State() from "draw-core";          // 0 none, 1 drawing, 2 finished this frame
import int DrawCore_Count() from "draw-core";
import int DrawCore_ChangedFrom() from "draw-core";    // first point placed again since last asked
import void DrawCore_Point(int, double &out, double &out, double &out) from "draw-core";
import void DrawCore_Cancel() from "draw-core";
import double DrawCore_PixelAngle(float, float) from "draw-core";
import bool DrawCore_OnPlane(float, float, double, double &out, double &out, double &out, double &out) from "draw-core";
```

Placements: 0 on surfaces, 1 on the level plane at `planeHeight` (no further than `airDistance`), 2 in the air at
`airDistance`. Call `DrawCore_Frame` every frame you want drawing; a frame without it puts the layer and ring away.

Needs host 0.31.0.
