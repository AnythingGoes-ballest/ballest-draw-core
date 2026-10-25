// Draw Core: the drawing that Inspect Draw and Draw Track share, as a library they import (each lists "draw-core"
// in its dependencies). It turns the left mouse button and the cursor into a stroke: points in the world, placed
// either on the surfaces under the cursor or on a level plane, sampled every few pixels along the cursor's path so
// fast strokes still follow what is under them. It also owns the see-through layer that keeps the game's camera
// (or the editor's selection) from taking the clicks while a tool is on, and the ring that shows the tool's size at
// the cursor.
//
// A client calls DrawCore_Frame once every frame it wants drawing (with what it wants: how points are placed, the
// brush's size, whether the cursor is over its own window), then reads the stroke: DrawCore_State, DrawCore_Count,
// DrawCore_ChangedFrom and DrawCore_Point. A frame without a call (the client stopped, or left its mode) puts the
// layer and the ring away and drops any stroke.
//
// Surface placement follows how 3D drawing tools put a cursor stroke on surfaces: Blender's surface strokes (only
// onto the chosen objects, with points that find no surface given depths between their neighbours), Gravity Sketch's
// guide surfaces (the brush stays on the surface until told otherwise) and "on" and "off" runs in Autodesk's guided
// curves. A stroke keeps to the surface it started on, traced on its own, so something in front of it never takes
// the line; off that surface's edge it stays at the line's depth until a surface carries the line on (its depth
// continues the line's), and then the points between are laid evenly between the two, so a line drawn across a jump
// bridges it.

// ---------------------------------------------------------------- what clients use

const int kPlaceSurface = 0;    // on surfaces (as above); over nothing, at the air distance
const int kPlacePlane = 1;      // on the level plane at the client's height, no further than the air distance
const int kPlaceAir = 2;        // in the air, the air distance from the camera

const int kStateNone = 0;       // no stroke
const int kStateDrawing = 1;    // the button is held: points are being added
const int kStateFinished = 2;   // let go this frame: the stroke's points are final (readable this frame only)

// ---------------------------------------------------------------- state

class Sample
{
    double ox, oy, oz, dx, dy, dz;
    double depth;               // how far along the ray the surface is (or the point, for an off one)
    bool on;
    bool atHit = false;         // placed on the surface: the hit point lifted by `lift` along its normal
    double px, py, pz;
}

const float kStepPixels = 4;            // the cursor's path is sampled this often
const int kMaxSteps = 96;               // samples per frame at most
const double kContinuity = 0.2;         // a surface counts if its depth is within this fraction of the last point's
const double kMinContinuity = 60;       // ... or within this many cm
const int kMaxPoints = 6000;            // per stroke

int placement = kPlaceSurface;
double planeHeight = 0;
double brush = 10;              // the brush's radius in the world (cm): the ring, and points lifted off surfaces by it
double spacing = 10;            // points at least this far apart (cm)
double airDistance = 1000;
double ringOverride = 0;        // > 0: the ring's radius in pixels (an eraser)
bool blocked = false;           // the cursor is over the client's own window
bool capturing = false;         // the client wants strokes (not just the layer and the ring)

int state = kStateNone;
array<Sample@> samples;
array<double> points;
int changedFrom = 0;
int lockedSurface = 0;
float lastMx, lastMy;
int calledFrame = -1;           // the frame of the client's last DrawCore_Frame
int frame = 0;

UI::Window@ catcher;
UI::Window@ ring;

// ---------------------------------------------------------------- the interface

// Once a frame from the client that is drawing. enabled: a tool is on (the layer takes the clicks, the ring shows);
// capture: strokes are made (false for an eraser, which only wants the layer and the ring).
void DrawCore_Frame(bool enabled, bool capture, bool overClientWindow, int place, double height, double brushRadius,
                    double pointSpacing, double air, double ringPixels)
{
    calledFrame = frame;
    placement = place;
    planeHeight = height;
    brush = brushRadius;
    spacing = pointSpacing > 1 ? pointSpacing : 1;
    airDistance = air;
    ringOverride = ringPixels;
    blocked = overClientWindow;
    capturing = enabled && capture;
    catcher.visible = enabled;
    if (state == kStateFinished)
        Reset();
    if (capturing)
        Capture();
    else if (state == kStateDrawing && points.length() >= 6)
        state = kStateFinished;         // the tool went off mid-stroke: the stroke so far is kept
    else
        Reset();
    UpdateRing(enabled);
}

int DrawCore_State() { return state; }
int DrawCore_Count() { return int(points.length() / 3); }

// The first point placed again since the client last asked (points over a gap are laid again when the line meets a
// surface); the count if none. Asking resets it.
int DrawCore_ChangedFrom()
{
    int c = changedFrom;
    changedFrom = DrawCore_Count();
    return c;
}

void DrawCore_Point(int i, double &out x, double &out y, double &out z)
{
    x = points[i * 3];
    y = points[i * 3 + 1];
    z = points[i * 3 + 2];
}

// Drops the stroke being drawn (the client's undo while drawing). The button has to be let go before a new one.
void DrawCore_Cancel()
{
    Reset();
    cancelled = true;
}
bool cancelled = false;

// How wide one pixel is as an angle (radians) at a point on screen: for measuring what is near the cursor on screen.
double DrawCore_PixelAngle(float mx, float my)
{
    double ox, oy, oz, ax, ay, az, bx, by, bz;
    if (!Camera::Deproject(mx, my, ox, oy, oz, ax, ay, az) || !Camera::Deproject(mx + 10, my, ox, oy, oz, bx, by, bz))
        return 0;
    double ex = bx - ax, ey = by - ay, ez = bz - az;
    return Math::sqrt(ex * ex + ey * ey + ez * ez) / 10;
}

// Where the cursor's ray meets the level plane at `height`; false if it doesn't (looking away from it).
bool DrawCore_OnPlane(float sx, float sy, double height, double &out x, double &out y, double &out z, double &out along)
{
    x = 0;
    y = 0;
    z = height;
    along = 0;
    double ox, oy, oz, dx, dy, dz;
    if (!Camera::Deproject(sx, sy, ox, oy, oz, dx, dy, dz) || Math::abs(dz) < 1e-4)
        return false;
    double t = (height - oz) / dz;
    if (t <= 0 || t > 500000)
        return false;
    x = ox + dx * t;
    y = oy + dy * t;
    along = t;
    return true;
}

// ---------------------------------------------------------------- capture

void Reset()
{
    state = kStateNone;
    samples.resize(0);
    points.resize(0);
    changedFrom = 0;
    lockedSurface = 0;
}

void Capture()
{
    float mx, my;
    if (state == kStateNone)
    {
        if (cancelled && Input::Down(Input::MouseLeft))
            return;
        cancelled = false;
        if (!Input::Pressed(Input::MouseLeft) || blocked || Input::Down(Input::Ctrl) || !Input::MousePosition(mx, my))
            return;
        state = kStateDrawing;
        SampleAt(mx, my);
        lastMx = mx;
        lastMy = my;
        return;
    }
    if (!Input::Down(Input::MouseLeft))
    {
        state = points.length() >= 6 ? kStateFinished : kStateNone;
        if (state == kStateNone)
            Reset();
        return;
    }
    if (!Input::MousePosition(mx, my))
        return;
    float ex = mx - lastMx, ey = my - lastMy;
    float moved = float(Math::sqrt(ex * ex + ey * ey));
    if (moved < 1)
        return;
    int steps = int(Math::ceil(moved / kStepPixels));
    if (steps > kMaxSteps)
        steps = kMaxSteps;
    for (int k = 1; k <= steps; k++)
        SampleAt(lastMx + ex * k / steps, lastMy + ey * k / steps);
    lastMx = mx;
    lastMy = my;
}

bool Continues(double depth, double from)
{
    double tolerance = from * kContinuity;
    return Math::abs(depth - from) <= (tolerance > kMinContinuity ? tolerance : kMinContinuity);
}

void PointOf(Sample@ sample, double &out x, double &out y, double &out z)
{
    if (sample.atHit)
    {
        x = sample.px;
        y = sample.py;
        z = sample.pz;
        return;
    }
    x = sample.ox + sample.dx * sample.depth;
    y = sample.oy + sample.dy * sample.depth;
    z = sample.oz + sample.dz * sample.depth;
}

void Place(Sample@ sample, uint index)
{
    double x, y, z;
    PointOf(sample, x, y, z);
    points[index * 3] = x;
    points[index * 3 + 1] = y;
    points[index * 3 + 2] = z;
    if (int(index) < changedFrom)
        changedFrom = index;
}

// The off samples before the newest on one get depths between the on samples either side (the first on sample's for
// a stroke that started over nothing).
void Bridge()
{
    int last = int(samples.length()) - 1;
    int before = last - 1;
    while (before >= 0 && !samples[before].on)
        before--;
    if (before == last - 1)
        return;
    double from = before >= 0 ? samples[before].depth : samples[last].depth;
    double to = samples[last].depth;
    for (int k = before + 1; k < last; k++)
    {
        double t = double(k - before) / double(last - before);
        samples[k].depth = from + (to - from) * t;
        samples[k].on = true;
        Place(samples[k], k);
    }
}

void Append(Sample@ sample)
{
    uint n = points.length();
    if (n >= uint(kMaxPoints * 3))
        return;
    double x, y, z;
    PointOf(sample, x, y, z);
    if (n >= 3)
    {
        double ex = x - points[n - 3], ey = y - points[n - 2], ez = z - points[n - 1];
        if (ex * ex + ey * ey + ez * ez < spacing * spacing)
        {
            // too close to keep, but a surface met again still settles the samples before it
            uint last = samples.length() - 1;
            if (sample.on && samples.length() > 0 && !samples[last].on)
            {
                samples[last].depth = sample.depth;
                samples[last].on = true;
                samples[last].atHit = sample.atHit;
                samples[last].px = sample.px;
                samples[last].py = sample.py;
                samples[last].pz = sample.pz;
                Place(samples[last], last);
                Bridge();
            }
            return;
        }
    }
    points.insertLast(x);
    points.insertLast(y);
    points.insertLast(z);
    samples.insertLast(sample);
    if (sample.on)
        Bridge();
}

// Puts a sample on a surface hit: lifted off it by the brush's radius, so a line lies on it.
void OnHit(Sample@ s, double x, double y, double z, double nx, double ny, double nz)
{
    s.px = x + nx * brush;
    s.py = y + ny * brush;
    s.pz = z + nz * brush;
    double ex = x - s.ox, ey = y - s.oy, ez = z - s.oz;
    s.depth = Math::sqrt(ex * ex + ey * ey + ez * ez);
    s.on = true;
    s.atHit = true;
}

// One sample of the cursor's path at (sx, sy).
void SampleAt(float sx, float sy)
{
    Sample s;
    if (!Camera::Deproject(sx, sy, s.ox, s.oy, s.oz, s.dx, s.dy, s.dz))
        return;
    if (placement == kPlaceAir)
    {
        s.depth = airDistance;
        s.on = true;
        Append(s);
        return;
    }
    if (placement == kPlacePlane)
    {
        double x, y, z, along;
        if (!DrawCore_OnPlane(sx, sy, planeHeight, x, y, z, along) || along > airDistance)
            return;                     // looking away from the plane, or at it near the horizon (too far to mean it)
        s.depth = along;
        s.on = true;
        Append(s);
        return;
    }
    bool started = samples.length() > 0;
    double from = started ? samples[samples.length() - 1].depth : airDistance;
    double x, y, z, nx, ny, nz;
    if (lockedSurface != 0 && Camera::PickOn(lockedSurface, sx, sy, x, y, z, nx, ny, nz))
    {
        OnHit(s, x, y, z, nx, ny, nz);
        if (Continues(s.depth, from))
        {
            Append(s);
            return;
        }
    }
    int surface;
    if (Camera::Pick(sx, sy, x, y, z, nx, ny, nz, surface))
    {
        OnHit(s, x, y, z, nx, ny, nz);
        if (!started || Continues(s.depth, from))
        {
            lockedSurface = surface;
            Append(s);
            return;
        }
    }
    // nothing that carries the line on: it stays in the air at its depth until a surface does
    Sample off;
    off.ox = s.ox;
    off.oy = s.oy;
    off.oz = s.oz;
    off.dx = s.dx;
    off.dy = s.dy;
    off.dz = s.dz;
    off.depth = from;
    off.on = false;
    Append(off);
}

// ---------------------------------------------------------------- the ring

// The ring's radius in pixels: the client's own (an eraser), or the brush as wide as it shows where a point would go
// (on the surface under the cursor, the plane, or at the air distance); 0 when there's nothing to show.
float RingPixels(float mx, float my)
{
    if (ringOverride > 0)
        return float(ringOverride);
    double angle = DrawCore_PixelAngle(mx, my);
    if (angle <= 0)
        return 0;
    double along = airDistance;
    if (state == kStateDrawing && samples.length() > 0)
        along = samples[samples.length() - 1].depth;
    else if (placement == kPlacePlane)
    {
        double x, y, z;
        if (!DrawCore_OnPlane(mx, my, planeHeight, x, y, z, along))
            return 0;
    }
    else if (placement == kPlaceSurface)
    {
        double x, y, z, nx, ny, nz;
        int surface;
        if (Camera::Pick(mx, my, x, y, z, nx, ny, nz, surface))
        {
            double ox, oy, oz, dx, dy, dz;
            if (Camera::Deproject(mx, my, ox, oy, oz, dx, dy, dz))
                along = Math::sqrt((x - ox) * (x - ox) + (y - oy) * (y - oy) + (z - oz) * (z - oz));
        }
    }
    return float(brush / (along * angle));
}

void UpdateRing(bool active)
{
    float mx, my;
    if (!active || blocked || !Input::MousePosition(mx, my))
    {
        ring.visible = false;
        return;
    }
    float r = RingPixels(mx, my);
    if (r <= 0)
    {
        ring.visible = false;
        return;
    }
    if (r < 2)
        r = 2;
    if (r > 400)
        r = 400;
    ring.SetRect(mx - r, my - r, 2 * r, 2 * r);
    ring.visible = true;
}

// ---------------------------------------------------------------- frame

void Main()
{
    @catcher = UI::CreateWindow();
    catcher.SetScreenSize(1, 1);
    catcher.SetBackground(0, 0, 0, 0);
    catcher.SetBlocksClicks(true);
    catcher.zOrder = 110;
    catcher.visible = false;

    @ring = UI::CreateWindow();
    ring.SetBackground(1, 1, 1, 0.18f);
    ring.SetPadding(0, 0);
    // set once: a corner radius past half the ring's size keeps it a circle at every size (setting it as the ring
    // grows built the window again each time: measured, every frame the cursor moved)
    ring.SetCornerRadius(400);
    ring.zOrder = 115;
    ring.visible = false;
}

void Update(float dt)
{
    // a client that didn't ask for drawing in its last frame has none: the layer and the ring go, a stroke is dropped
    if (calledFrame < frame - 1)
    {
        catcher.visible = false;
        ring.visible = false;
        Reset();
    }
    frame++;
}
