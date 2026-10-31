#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// A page curl: the page wraps around a cylinder whose axis follows the finger.
//
// The layer is two pages wide: the current page (what lifts) in [0, w), and the page whose
// face shows on the back of a turning leaf in [w, 2w). Only [0, w) is drawn.
//
// `leaf` is the part of the page that turns, as (minX, minY, maxX, maxY): the whole page,
// or the right page of a spread. `corner` is the corner being lifted and `finger` where it
// is now. `radius` is the cylinder's radius. `paper` is the theme's background, `backMode`
// 0 shows a faint mirror of the front on the back (one page), 1 shows the next spread's
// left page there (a spread's leaf).

static bool inside(float2 p, float4 r) {
    return p.x >= r.x && p.x < r.z && p.y >= r.y && p.y < r.w;
}

[[ stitchable ]] half4 pageCurl(float2 position,
                                SwiftUI::Layer layer,
                                float w,
                                float4 leaf,
                                float2 corner,
                                float2 finger,
                                float radius,
                                half4 paper,
                                float backMode) {
    float2 p = position;
    if (p.x >= w) { return half4(0); }

    float2 toCorner = corner - finger;
    float len = length(toCorner);
    if (len < 0.5) { return layer.sample(p); }

    float2 dir = toCorner / len;
    // The fold line passes through the midpoint, shifted so the curled tip lands at the finger.
    float2 mid = (corner + finger) * 0.5 - dir * (M_PI_F * radius * 0.5);
    float r = max(radius, 1.0);
    float d = dot(p - mid, dir);

    // 1. The back of the leaf, which lies on top of everything.
    if (d < r) {
        float sBack = d >= 0.0 ? r * (M_PI_F - asin(clamp(d / r, -1.0, 1.0))) : M_PI_F * r - d;
        float2 src = p + dir * (sBack - d);
        if (inside(src, leaf)) {
            half4 face;
            if (backMode > 0.5) {
                // A spread's leaf: its back is the next spread's left page, mirrored about the spine.
                float spine = leaf.x;
                float2 q = float2(w + (2.0 * spine - src.x), src.y);
                face = layer.sample(q);
            } else {
                half4 front = layer.sample(src);
                face = mix(paper, front, half(0.14));
            }
            // Light the cylinder: brightest at its crown, a little darker as it rolls away.
            half shade = d >= 0.0 ? half(0.86 + 0.14 * sin(M_PI_F * 0.5 * (1.0 - d / r))) : half(0.97);
            return half4(face.rgb * shade, 1.0);
        }
    }

    bool inLeaf = inside(p, leaf);
    if (inLeaf) {
        if (d >= r) {
            // Lifted away: show the page beneath, darkened by the curl's shadow near the fold.
            float t = clamp((d - r) / (r * 2.2), 0.0, 1.0);
            half a = half(0.28 * (1.0 - t) * (1.0 - t));
            return half4(0, 0, 0, a);
        }
        if (d >= 0.0) {
            // The underside of the cylinder: the front, compressed as it rolls.
            float sFront = r * asin(clamp(d / r, -1.0, 1.0));
            float2 src = p + dir * (sFront - d);
            if (inside(src, leaf)) {
                half4 front = layer.sample(src);
                half shade = half(1.0 - 0.35 * pow(d / r, 2.0));
                return half4(front.rgb * shade, front.a);
            }
            return half4(0, 0, 0, 0.18);
        }
        // Flat, but in the shadow the back of the leaf casts just past the fold line.
        half4 front = layer.sample(p);
        float edge = clamp(-d / (r * 0.9), 0.0, 1.0);
        half dim = half(1.0 - 0.12 * (1.0 - edge));
        return half4(front.rgb * dim, front.a);
    }
    return layer.sample(p);
}
