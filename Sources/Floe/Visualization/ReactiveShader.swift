/// Compiled with Metal at runtime so the CLT-only build needs no Metal compiler.
/// One library holds both live backgrounds; each gets its own pipeline, built once.
enum ReactiveShader {
    static let source = prelude + fluid + beams

    /// The full-screen triangle, value noise and the legibility limiter.
    private static let prelude = #"""
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 position [[position]]; float2 uv; };
    vertex Vertex floeBackgroundVertex(uint id [[vertex_id]]) {
        float2 p = id == 0 ? float2(-1, -1) : (id == 1 ? float2(3, -1) : float2(-1, 3));
        return { float4(p, 0, 1), p * 0.5 + 0.5 };
    }
    static float hash21(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }
    static float noise(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 s = f * f * (3 - 2 * f);
        return mix(mix(hash21(i), hash21(i + float2(1, 0)), s.x),
                   mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), s.x), s.y);
    }
    static float fbm(float2 p) {
        float sum = 0, amplitude = 0.5;
        for (int i = 0; i < 4; i++) {
            sum += amplitude * noise(p);
            p = float2(0.8 * p.x - 0.6 * p.y, 0.6 * p.x + 0.8 * p.y) * 2.03 + 17.1;
            amplitude *= 0.5;
        }
        return sum / 0.9375;
    }
    /// White text stays readable: luma above the knee is compressed so it never
    /// passes the limit, keeping the colour's hue.
    static float3 limitLuma(float3 c, float knee, float limit) {
        c = max(c, 0.0f);
        float y = dot(c, float3(0.2126, 0.7152, 0.0722));
        if (y <= knee) return c;
        float range = limit - knee;
        return c * ((knee + range * (1 - exp(-(y - knee) / range))) / y);
    }

    """#

    /// Ink in water: the cover's colours ride slow blobs through a domain-warped
    /// current and merge where they meet. A beat jolts the field and sends a
    /// ripple out from where it lands; the glow swells on the brightest ink.
    private static let fluid = #"""
    // motion: flow clock, energy, glow. size: width, height, punch.
    // shake: jolt xy, ripple strength, ripple age. ripple: ripple centre (uv).
    struct FluidUniforms { float4 colors[5]; float4 motion; float4 size; float4 shake; float4 ripple; };
    fragment float4 floeFluidFragment(Vertex in [[stage_in]], constant FluidUniforms& u [[buffer(0)]]) {
        float t = u.motion.x;
        float energy = u.motion.y;
        float glow = u.motion.z;
        float aspect = u.size.x / max(u.size.y, 1.0f);
        float2 middle = float2(0.5 * aspect, 0.5);
        float2 p = float2(in.uv.x * aspect, in.uv.y);

        // Shake: the field punches in and jolts, and a ring travels out from the hit.
        p = middle + (p - middle) * (1 - u.size.z) + u.shake.xy;
        float2 fromHit = p - float2(u.ripple.x * aspect, u.ripple.y);
        float hitDistance = length(fromHit);
        float age = u.shake.w;
        float ring = exp(-pow((hitDistance - 0.05 - age * 1.3) / 0.09, 2)) * exp(-age * 3.5) * u.shake.z;
        p += fromHit / max(hitDistance, 0.001f) * ring * 0.05;

        // Two layers of warp turn round blobs into swirling ink.
        float2 q = p * 1.3;
        float2 warp = float2(fbm(q + float2(0, t * 0.12)), fbm(q + float2(5.2, 1.3) - t * 0.1));
        float2 curl = float2(fbm(q + 2.8 * warp + float2(1.7, 9.2) + t * 0.06),
                             fbm(q + 2.8 * warp + float2(8.3, 2.8) - t * 0.08));
        float2 w = p + (curl - 0.5) * 0.75;

        float3 ink = 0;
        float field = 0, halo = 0;
        for (int i = 0; i < 6; i++) {
            float fi = float(i);
            float2 c = float2((0.5 + 0.4 * sin(t * (0.21 + 0.037 * fi) + fi * 2.39)) * aspect,
                              0.5 + 0.38 * sin(t * (0.17 + 0.045 * fi) + fi * 1.31 + 1.6));
            float radius = 0.2 + 0.05 * sin(t * 0.4 + fi * 1.9);
            float d2 = distance_squared(w, c) / (radius * radius);
            float k = exp(-d2);
            ink += u.colors[i % 5].rgb * k;
            field += k;
            halo += exp(-d2 * 0.22);
        }
        ink /= max(field, 0.0001f);
        // Pale covers keep their hue but not their lightness, or they'd wash the frame out.
        ink *= min(1.0f, 0.42f / max(dot(ink, float3(0.2126, 0.7152, 0.0722)), 0.01f));
        float body = smoothstep(0.06, 0.9, field);
        float strands = fbm(w * 2.4 + curl * 1.6 - t * 0.04);

        float3 color = ink * (0.055 + 0.06 * strands);
        color += ink * body * (0.23 + 0.32 * strands) * (0.85 + 0.35 * energy);
        // The glow blooms out of the bright ink and pulses with energy and beats.
        float bloom = glow / (1 + 0.35 * glow);
        float core = smoothstep(0.35, 1.3, field);
        color += ink * (core * 0.75 + min(halo, 1.5f) * 0.06) * bloom;
        color += ink * ring * 0.4;
        color = limitLuma(color, 0.38, 0.6);
        float alpha = 0.9;
        return float4(min(color, 1.0f) * alpha, alpha); // premultiplied, over the cover backdrop
    }

    """#

    /// Moving heads on a truss along the top edge (and two from the floor on a
    /// drop) cut narrow cones through drifting haze, each with a hot core and a
    /// lens flare at its source, added together like real light. Everything
    /// else stays dark, so only the beams and flares are bright.
    private static let beams = #"""
    // motion: haze clock, shimmer, strobe flash, glow. size: width, height, heads, floor level.
    // floor: floor angle, spread, two palette slots. heads: angle, intensity, spread, palette slot.
    struct BeamUniforms { float4 colors[5]; float4 motion; float4 size; float4 floor; float4 heads[8]; };
    /// Light scattered by the haze along one cone, brightest at its core.
    static float3 beam(float2 p, float2 source, float2 dir, float spread, float intensity,
                       float3 color, float density, float glow) {
        float2 v = p - source;
        float along = dot(v, dir);
        if (along <= 0 || intensity <= 0.001) return 0;
        float across = dot(v, float2(-dir.y, dir.x));
        float width = 0.006 + along * spread;
        float a2 = across * across / (width * width);
        float cone = exp(-a2 * 1.5) * (0.12 + 0.88 * density) * 0.75;
        float spill = exp(-a2 * 0.08) * 0.05 * glow * density;
        float core = exp(-a2 * 18) * exp(-along * 1.6);
        float falloff = 1 / (1 + along * along * 0.6);
        return (color * (cone + spill) + mix(color, float3(1), 0.6) * core * 0.6) * intensity * falloff;
    }
    /// The lens at a beam's source: a hot disk, a soft halo and a sideways streak.
    static float3 flare(float2 p, float2 source, float intensity, float3 color, float glow) {
        float2 d = p - source;
        float r2 = dot(d, d);
        float disk = exp(-r2 * 1400);
        float streak = exp(-d.y * d.y * 3500 - abs(d.x) * 9) * 0.3;
        float halo = exp(-r2 * 45) * 0.16;
        return (mix(color, float3(1), 0.75) * (disk * 1.6 + streak) + color * halo) * intensity * (0.6 + 0.4 * glow);
    }
    fragment float4 floeBeamsFragment(Vertex in [[stage_in]], constant BeamUniforms& u [[buffer(0)]]) {
        float aspect = u.size.x / max(u.size.y, 1.0f);
        float2 p = float2(in.uv.x * aspect, in.uv.y);
        float haze = u.motion.x;
        float glow = u.motion.w;

        // Smoke drifts across the stage; the highs make it glitter where it's lit.
        float smoke = fbm(p * float2(1.6, 2.4) + float2(haze * 0.08, -haze * 0.03));
        float wisps = fbm(p * float2(4.5, 6.5) + float2(-haze * 0.2, haze * 0.07));
        float density = 0.08 + 1.9 * smoke * smoke + 0.45 * wisps * smoke;
        density *= 1 + u.motion.y * (noise(p * 28 + float2(haze * 3.1, -haze * 2.3)) - 0.5) * 0.9;

        float3 light = 0;
        int count = int(u.size.z);
        for (int i = 0; i < 8; i++) {
            if (i >= count) break;
            float4 h = u.heads[i];
            float3 color = u.colors[int(h.w) % 5].rgb;
            float2 source = float2((float(i) + 0.5) / float(count) * aspect, 0.985);
            light += beam(p, source, float2(sin(h.x), -cos(h.x)), h.z, h.y, color, density, glow);
            light += flare(p, source, h.y, color, glow);
        }
        float floorLevel = u.size.w;
        if (floorLevel > 0.005) {
            float a = u.floor.x;
            float3 left = u.colors[int(u.floor.w) % 5].rgb, right = u.colors[int(u.floor.z) % 5].rgb;
            light += beam(p, float2(0, 0.015), float2(sin(a), cos(a)), u.floor.y, floorLevel, left, density, glow);
            light += beam(p, float2(aspect, 0.015), float2(-sin(a), cos(a)), u.floor.y, floorLevel, right, density, glow);
            light += flare(p, float2(0.01, 0.015), floorLevel, left, glow);
            light += flare(p, float2(aspect - 0.01, 0.015), floorLevel, right, glow);
        }

        float3 average = (u.colors[0].rgb + u.colors[1].rgb + u.colors[2].rgb + u.colors[3].rgb + u.colors[4].rgb) * 0.2;
        float3 color = float3(0.01, 0.011, 0.016) + average * smoke * 0.035 + light;
        // The opt-in strobe lights the whole haze, never more than three times a second.
        color += mix(average, float3(1), 0.7) * u.motion.z * (0.25 + 0.2 * density);
        color = 1 - exp(-color * 1.15); // highlights roll off toward white instead of clipping
        float alpha = clamp(0.86 + dot(color, float3(0.33)) * 0.3, 0.0f, 0.97f);
        return float4(color * alpha, alpha); // premultiplied, over the cover backdrop
    }
    """#
}
