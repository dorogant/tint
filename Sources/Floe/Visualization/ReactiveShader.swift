/// Compiled with Metal at runtime so the CLT-only build needs no Metal compiler.
/// A stage of light beams rises from the bottom edge, bass in the middle: each
/// beam's reach and brightness follow its part of the spectrum while it sways.
/// Slow colour clouds drift behind them and a bass bloom pulses from below.
enum ReactiveShader {
    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;
    // motion: time, energy, reactivity, bass. beams: 12 smoothed levels.
    struct Uniforms { float4 color; float4 motion; float4 size; float4 beams[3]; };
    struct Vertex { float4 position [[position]]; float2 uv; };
    vertex Vertex floeBackgroundVertex(uint id [[vertex_id]]) {
        float2 p = id == 0 ? float2(-1, -1) : (id == 1 ? float2(3, -1) : float2(-1, 3));
        return { float4(p, 0, 1), p * 0.5 + 0.5 };
    }
    fragment float4 floeBackgroundFragment(Vertex in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
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
