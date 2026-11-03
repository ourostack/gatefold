#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// A page curl: the page wraps around a cylinder whose axis follows the finger.
//
// The layer is the current page (what lifts), `w` wide. `back` is the destination page, whose
// left half shows on the back of a spread's turning leaf; `mirror` is 1 when the whole effect is
// drawn mirrored (turning backward), so `back` is sampled flipped to match.
//
// `leaf` is the part of the page that turns, as (minX, minY, maxX, maxY): the whole page,
// or the right page of a spread. `corner` is the corner being lifted and `finger` where it
// is now. `radius` is the cylinder's radius. `paper` and `ink` are the theme's background and
// text, `backMode` 0 shows a faint mirror of the front on the back (one page), 1 shows the next
// spread's left page there (a spread's leaf). `dark` is 1 for a dark theme: paper there is lit by
// a soft highlight along the roll instead of being darkened, so the leaf never reads as a hole.

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
                                half4 ink,
                                float backMode,
                                float dark,
                                texture2d<half> back,
                                float mirror) {
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
                float2 q = float2(2.0 * spine - src.x, src.y);
                float u = q.x / w;
                if (mirror > 0.5) { u = 1.0 - u; }
                constexpr sampler s(address::clamp_to_edge, filter::linear);
                face = back.sample(s, float2(u, q.y / leaf.w));
                if (face.a < 0.5) { face = paper; }
            } else {
                // The back of a printed page: paper a shade toward the ink, the front's words
                // showing through faintly, mirrored.
                half4 front = layer.sample(src);
                // A dark page's back is barely lighter than its paper, its words showing through more,
                // so a quick riffle reads as leaves of the same book, not grey card.
                half4 back = mix(paper, ink, half(dark > 0.5 ? 0.05 : 0.10));
                face = mix(back, front, half(dark > 0.5 ? 0.28 : 0.15));
            }
            // Light the cylinder. Where the paper rolls toward the light (its crown, d near r) it
            // catches a highlight; it settles as it lies flatter.
            float crown = d >= 0.0 ? sin(M_PI_F * 0.5 * (1.0 - d / r)) : 0.0;
            float rim = d >= 0.0 ? pow(clamp(d / r, 0.0, 1.0), 6.0) : 0.0;
            half3 rgb;
            if (dark > 0.5) {
                // A highlight band along the roll that falls away across the flat back, as a sheet
                // catches light where it bends, never one even lift.
                float fall = d >= 0.0 ? 0.0 : clamp(-d / (r * 6.0), 0.0, 1.0);
                rgb = face.rgb + half3(0.02 + 0.07 * crown + 0.06 * (1.0 - fall)) + half3(0.10 * rim);
            } else {
                half shade = d >= 0.0 ? half(0.88 + 0.12 * crown) : half(0.97);
                rgb = face.rgb * shade + half3(0.08 * rim);
            }
            return half4(min(rgb, half3(1.0)), 1.0);
        }
    }

    bool inLeaf = inside(p, leaf);
    if (inLeaf) {
        if (d >= r) {
            // Lifted away: show the page beneath, darkened by the leaf's cast shadow, which falls
            // off over 24 pt the way a sheet's shadow does on paper.
            // A leaf flattening as it lands (a spread's, whose roll shrinks) casts less and less.
            float t = clamp((d - r) / 24.0, 0.0, 1.0);
            half a = half(0.35 * (1.0 - t) * (1.0 - t) * clamp(radius / 18.0, 0.0, 1.0));
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
