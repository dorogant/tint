/// Compiled with Metal at runtime so the CLT-only build needs no Metal compiler.
enum ReactiveShader {
    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;
    struct Uniforms { float4 color; float4 motion; float4 size; };
    struct Vertex { float4 position [[position]]; float2 uv; };
    vertex Vertex floeBackgroundVertex(uint id [[vertex_id]]) {
        float2 p = id == 0 ? float2(-1, -1) : (id == 1 ? float2(3, -1) : float2(-1, 3));
        return { float4(p, 0, 1), p * 0.5 + 0.5 };
    }
    fragment float4 floeBackgroundFragment(Vertex in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float t = u.motion.x * 0.06;
        float pulse = clamp(u.motion.y * u.motion.z, 0.0f, 1.0f);
        float2 uv = in.uv;
        float2 a = float2(0.28 + 0.13 * sin(t), 0.35 + 0.13 * cos(t * 0.8));
        float2 b = float2(0.70 + 0.11 * cos(t * 0.7), 0.62 + 0.12 * sin(t * 0.6));
        float2 scale = float2(u.size.x / max(u.size.y, 1.0f), 1);
        float2 da = (uv - a) * scale, db = (uv - b) * scale;
        float clouds = exp(-dot(da, da) * (5.5 - pulse * 2)) + 0.7 * exp(-dot(db, db) * 4);
        float ripple = sin(uv.x * 7 + uv.y * 5 + t) * 0.025;
        float3 color = float3(0.025, 0.03, 0.04) + u.color.rgb * (0.16 + 0.25 * clouds + ripple) * (1 + pulse * 0.65);
        return float4(color * 0.65, 0.65); // premultiplied, translucent over the cover backdrop
    }
    """#
}
