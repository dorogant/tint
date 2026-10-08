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

    /// A stage of light beams rises from the bottom edge, bass in the middle: each
    /// beam's reach and brightness follow its part of the spectrum while it sways.
    /// Slow colour clouds drift behind them and a bass bloom pulses from below.
    private static let beams = #"""
    // motion: time, energy, reactivity, bass. beams: 12 smoothed levels.
    struct BeamUniforms { float4 color; float4 motion; float4 size; float4 beams[3]; };
    fragment float4 floeBeamsFragment(Vertex in [[stage_in]], constant BeamUniforms& u [[buffer(0)]]) {
        float t = u.motion.x;
        float react = u.motion.z;
        float energy = clamp(u.motion.y * react, 0.0f, 1.0f);
        float bass = clamp(u.motion.w * react, 0.0f, 1.0f);
        float aspect = u.size.x / max(u.size.y, 1.0f);
        float2 p = float2(in.uv.x * aspect, in.uv.y);

        float ct = t * (0.06 + 0.05 * energy);
        float2 a = float2((0.28 + 0.13 * sin(ct)) * aspect, 0.35 + 0.13 * cos(ct * 0.8));
        float2 b = float2((0.70 + 0.11 * cos(ct * 0.7)) * aspect, 0.62 + 0.12 * sin(ct * 0.6));
        float clouds = exp(-distance_squared(p, a) * 5.5) + 0.7 * exp(-distance_squared(p, b) * 4);

        float light = 0;
        for (int i = 0; i < 12; i++) {
            float level = clamp(u.beams[i / 4][i % 4] * react, 0.0f, 1.2f);
            float x = (float(i) + 0.5) / 12.0;
            // Lean outward from the centre and sway, each beam at its own pace.
            float angle = (x - 0.5) * 0.9 + 0.2 * sin(t * (0.35 + 0.035 * float(i)) + float(i) * 1.7);
            float2 dir = float2(sin(angle), cos(angle));
            float2 v = p - float2(x * aspect, -0.06);
            float along = dot(v, dir);
            float across = dot(v, float2(dir.y, -dir.x));
            float width = 0.012 + max(along, 0.0f) * 0.085;
            float reach = 0.2 + 0.95 * level;
            float beam = exp(-(across * across) / (width * width))
                * (1 - smoothstep(reach * 0.3, reach, along)) * step(0.0f, along);
            light += beam * (0.2 + 0.8 * level);
        }
        float bloom = exp(-distance_squared(p, float2(0.5 * aspect, -0.15)) * 2.5) * bass;

        float3 tint = u.color.rgb;
        float3 color = float3(0.025, 0.03, 0.04) + tint * (0.16 + 0.25 * clouds) * (1 + energy * 0.5);
        color += mix(tint, float3(1), 0.35) * (light * 0.3 + bloom * 0.35);
        float alpha = clamp(0.65 + light * 0.12 + bloom * 0.15, 0.0f, 0.9f);
        return float4(min(color, 1.0f) * alpha, alpha); // premultiplied, over the cover backdrop
    }
    """#
}
