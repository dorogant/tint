/// Compiled with Metal at runtime so the CLT-only build needs no Metal compiler.
/// One library holds every live background; each gets its own pipeline, built once.
enum ReactiveShader {
    static let source = prelude + fluid + beams

    /// The full-screen triangle, value noise, anti-aliased lines, dithering and
    /// the legibility limiter.
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
        float2 i = floor(p), f = p - i;
        half2 s = half2(f * f * (3.0f - 2.0f * f));
        half a = half(hash21(i)), b = half(hash21(i + float2(1, 0)));
        half c = half(hash21(i + float2(0, 1))), d = half(hash21(i + float2(1, 1)));
        return float(mix(mix(a, b, s.x), mix(c, d, s.x), s.y));
    }
    static float fbm(float2 p) {
        float sum = 0, amplitude = 0.5;
        for (int i = 0; i < 4; i++) {
            sum += amplitude * noise(p);
            p = float2(0.8f * p.x - 0.6f * p.y, 0.6f * p.x + 0.8f * p.y) * 2.03f + 17.1f;
            amplitude *= 0.5f;
        }
        return sum * (1.0f / 0.9375f);
    }
    /// Three-octave fbm for low-frequency domain warps where the fourth octave
    /// (1/16 amplitude) is smoothed away by the next warp layer anyway.
    static float fbm3(float2 p) {
        float sum = 0.5f * noise(p);
        p = float2(0.8f * p.x - 0.6f * p.y, 0.6f * p.x + 0.8f * p.y) * 2.03f + 17.1f;
        sum += 0.25f * noise(p);
        p = float2(0.8f * p.x - 0.6f * p.y, 0.6f * p.x + 0.8f * p.y) * 2.03f + 17.1f;
        sum += 0.125f * noise(p);
        return sum * (1.0f / 0.875f);
    }
    /// A Gaussian line profile pre-filtered for the pixel footprint: a line
    /// thinner than a pixel widens to one and dims to match, so its light is
    /// kept but it never breaks into stair steps.
    static float line(float across2, float sigma, float pixel2) {
        float s2 = sigma * sigma + pixel2;
        return exp2((-0.5f * 1.44269504f) * across2 / s2) * sigma * rsqrt(s2);
    }
    /// Interleaved gradient noise, plus or minus half a code value, so dark
    /// gradients don't band in 8 bits.
    static half dither(float2 pixel) {
        return half((fract(52.9829189f * fract(dot(pixel, float2(0.06711056f, 0.00583715f)))) - 0.5f) * (1.0f / 255.0f));
    }
    /// White text stays readable: luma above the knee is compressed so it never
    /// passes the limit, keeping the colour's hue.
    static half3 limitLuma(half3 c, half knee, half limit) {
        c = max(c, 0.0h);
        half y = dot(c, half3(0.2126h, 0.7152h, 0.0722h));
        if (y <= knee) return c;
        half range = limit - knee;
        return c * ((knee + range * (1.0h - exp2((-(y - knee) / range) * 1.442695h))) / y);
    }

    """#

    /// Ink in water: the cover's colours ride slow blobs through a domain-warped
    /// current and merge where they meet. The bass breathes the field in from
    /// the centre, the glow swells on the brightest ink, the mids fill it out
    /// and the highs bring up its fine strands.
    private static let fluid = #"""
    // motion: flow clock, energy, glow, detail (highs). size: width, height, breath (bass), body (mids).
    // blobs: precomputed centre x (aspect-scaled), centre y, inverse squared radius, spare.
    struct FluidUniforms { float4 colors[5]; float4 motion; float4 size; float4 blobs[6]; };
    fragment half4 floeFluidFragment(Vertex in [[stage_in]], constant FluidUniforms& u [[buffer(0)]]) {
        float t = u.motion.x;
        half energy = half(u.motion.y);
        half glow = half(u.motion.z);
        half detail = half(u.motion.w);
        half body = half(u.size.w);
        float aspect = u.size.x / max(u.size.y, 1.0f);
        float2 middle = float2(0.5f * aspect, 0.5f);
        float2 p = float2(in.uv.x * aspect, in.uv.y);

        // Breath: the whole field draws in toward the centre with the bass and eases back.
        p = middle + (p - middle) * (1.0f - 0.035f * u.size.z);

        // Two layers of warp turn round blobs into swirling ink.
        float2 q = p * 1.3f;
        float2 warp = float2(fbm3(q + float2(0, t * 0.12f)), fbm3(q + float2(5.2f, 1.3f) - t * 0.1f));
        float2 qw = q + 2.8f * warp;
        float2 curl = float2(fbm3(qw + float2(1.7f, 9.2f) + t * 0.06f),
                             fbm3(qw + float2(8.3f, 2.8f) - t * 0.08f));
        float2 w = p + (curl - 0.5f) * 0.75f;

        half3 ink = 0;
        half field = 0, halo = 0;
        for (int i = 0; i < 6; i++) {
            float4 b = u.blobs[i];
            float2 d = w - b.xy;
            float d2 = dot(d, d) * b.z;
            half k = half(exp2(d2 * -1.44269504f));
            ink += half3(u.colors[i % 5].rgb) * k;
            field += k;
            halo += half(exp2(d2 * (-0.22f * 1.44269504f)));
        }
        ink /= max(field, 0.0001h);
        // Pale covers keep their hue but not their lightness, or they'd wash the frame out.
        ink *= min(1.0h, 0.42h / max(dot(ink, half3(0.2126h, 0.7152h, 0.0722h)), 0.01h));
        half fill = smoothstep(0.06h - 0.03h * body, 0.9h, field);
        half strands = half(fbm(w * 2.4f + curl * 1.6f - t * 0.04f));
        // The highs sharpen the strands: more contrast between thread and gap.
        strands = mix(strands, smoothstep(0.3h, 0.75h, strands), 0.6h * detail);

        half3 color = ink * (0.055h + 0.06h * strands);
        color += ink * fill * (0.23h + 0.32h * strands) * (0.8h + 0.25h * energy + 0.2h * body);
        // The glow blooms out of the bright ink with energy and kicks.
        half bloom = glow / (1.0h + 0.35h * glow);
        half core = smoothstep(0.35h, 1.3h, field);
        color += ink * (core * 0.75h + min(halo, 1.5h) * 0.06h) * bloom;
        color = limitLuma(color, 0.38h, 0.6h);
        half alpha = 0.9h;
        return half4(min(color, 1.0h) * alpha + dither(in.position.xy), alpha); // premultiplied, over the cover backdrop
    }

    """#

    /// Moving heads on a truss along the top edge (and two from the floor on a
    /// drop) cut narrow cones through drifting haze, each with a hot core and a
    /// lens flare at its source, added together like real light. Everything
    /// else stays dark, so only the beams and flares are bright.
    private static let beams = #"""
    // motion: haze clock, spare, strobe flash, glow. size: width, height, heads, floor level.
    // floor: floor angle, floor spread, haze fill (mids), sin(floor angle). haze: haze colour, neutral cover.
    // average: palette average rgb, cos(floor angle).
    // heads: angle, intensity, spread, glint. tints: head colour, sin(angle).
    // geometry: precomputed source x, dir x, dir y, spare.
    struct BeamUniforms {
        float4 colors[5]; float4 motion; float4 size; float4 floor; float4 haze; float4 average;
        float4 floorColors[2]; float4 heads[8]; float4 tints[8]; float4 geometry[8];
    };
    /// Light scattered by the haze along one cone, brightest at its core. Every
    /// profile is pre-filtered for the pixel size, so thin beams stay smooth.
    static half3 beam(float2 p, float2 source, float2 dir, float spread, float intensity, half3 color,
                      float density, float glow, float glint, float pixel, float pixel2, float drift, float seed) {
        float2 v = p - source;
        float along = dot(v, dir);
        if (along <= 0 || intensity <= 0.001f) return 0;
        float across = dot(v, float2(-dir.y, dir.x));
        float width = 0.006f + along * spread;
        float absAcross = abs(across);
        if (absAcross > width * 6.0f + 3.0f * pixel) return 0; // under a thousandth this far out
        float across2 = across * across;
        float invWidth = 1.0f / width;
        float cone = line(across2, width * 0.58f, pixel2) * (0.12f + 0.88f * density) * 0.75f;
        float spill = exp2((-0.08f * 1.44269504f) * across2 * invWidth * invWidth) * 0.05f * glow * density;
        // Hats: motes inside the beam catch the light as they drift down it. They
        // live in the beam's own coordinates, so they move with it and never sit
        // on the screen, and only the core shows them. Outside 1.2 * width the
        // core Gaussian is under 1e-10, so both core and mote noise are skipped.
        half core = 0;
        if (absAcross < width * 1.2f + 3.0f * pixel) {
            float motes = 0;
            if (glint > 0.01f) {
                float n = noise(float2(along * 70.0f - drift * 4.0f, across * invWidth * 2.5f + seed));
                motes = smoothstep(0.7f, 1.0f, n) * glint;
            }
            core = half(line(across2, width * 0.17f, pixel2) * exp2((-1.6f * 1.44269504f) * along)
                        * (1.0f + 0.6f * glint + 1.5f * motes));
        }
        half gain = half(intensity / (1.0f + along * along * 0.6f) * smoothstep(0.0f, 0.015f, along));
        return (color * half(cone + spill) + mix(color, half3(1.0h), 0.6h) * (core * 0.6h)) * gain;
    }
    /// The lens at a beam's source: a hot disk, a soft halo and a sideways streak.
    static half3 flare(float2 p, float2 source, float intensity, half3 color, float glow) {
        float2 d = p - source;
        float r2 = dot(d, d);
        if (r2 > 0.12f) return 0; // the halo is under a thousandth this far out
        half halo = half(exp2((-45.0f * 1.44269504f) * r2) * 0.16f);
        half hot = 0;
        if (r2 < 0.015f) {
            hot += half(exp2((-1400.0f * 1.44269504f) * r2) * 1.6f);
        }
        float dy2 = d.y * d.y;
        if (dy2 < 0.005f) {
            hot += half(exp2((dy2 * -3500.0f - abs(d.x) * 9.0f) * 1.44269504f) * 0.3f);
        }
        return (mix(color, half3(1.0h), 0.75h) * hot + color * halo) * half(intensity * (0.6f + 0.4f * glow));
    }
    /// Stage fog: large, soft volumes that drift sideways and slowly curl, with
    /// gentler billows inside them, and nothing smaller than a tenth of the
    /// screen, so it reads as smoke rather than smudges on the glass. It's all
    /// soft, so it's drawn at a quarter of the resolution and filtered up by the
    /// beams pass. Returns the fog's density and a billow term, both about 0…1.
    fragment half2 floeHazeFragment(Vertex in [[stage_in]], constant BeamUniforms& u [[buffer(0)]]) {
        float aspect = u.size.x / max(u.size.y, 1.0f);
        float2 p = float2(in.uv.x * aspect, in.uv.y);
        float t = u.motion.x;
        // A slow warp makes the volumes roll and curl instead of sliding as one.
        float2 warp = float2(fbm(p * 0.6f + float2(t * 0.03f, 3.1f)), fbm(p * 0.6f + float2(7.4f, -t * 0.025f)));
        float2 q = p + (warp - 0.5f) * 0.9f;
        float fog = fbm(q * float2(0.9f, 1.3f) + float2(t * 0.05f, -t * 0.012f));
        float billow = fbm(q * 1.6f + float2(-t * 0.08f, t * 0.03f) + warp * 1.5f);
        return half2(half(fog), half(billow));
    }
    /// A B-spline filtered sample from four bilinear taps: upscaling the
    /// quarter-resolution fog by four leaves no diamonds or creases.
    static half2 smoothSample(texture2d<half> map, float2 uv) {
        constexpr sampler filtered(filter::linear, address::clamp_to_edge);
        float2 size = float2(map.get_width(), map.get_height());
        float2 invSize = 1.0f / size;
        float2 st = uv * size - 0.5f;
        float2 i = floor(st), f = st - i;
        float2 f2 = f * f, f3 = f2 * f;
        float2 w0 = (1.0f - 3.0f * f + 3.0f * f2 - f3) * (1.0f / 6.0f);
        float2 w1 = (4.0f - 6.0f * f2 + 3.0f * f3) * (1.0f / 6.0f);
        float2 w2 = (1.0f + 3.0f * f + 3.0f * f2 - 3.0f * f3) * (1.0f / 6.0f);
        float2 w3 = f3 * (1.0f / 6.0f);
        float2 g0 = w0 + w1, g1 = w2 + w3;
        float2 h0 = (i - 0.5f + w1 / g0) * invSize, h1 = (i + 1.5f + w3 / g1) * invSize;
        half2 gx = half2(g0.x, g1.x), gy = half2(g0.y, g1.y);
        return gy.x * (gx.x * map.sample(filtered, float2(h0.x, h0.y)).xy + gx.y * map.sample(filtered, float2(h1.x, h0.y)).xy)
             + gy.y * (gx.x * map.sample(filtered, float2(h0.x, h1.y)).xy + gx.y * map.sample(filtered, float2(h1.x, h1.y)).xy);
    }
    fragment half4 floeBeamsFragment(Vertex in [[stage_in]], constant BeamUniforms& u [[buffer(0)]],
                                     texture2d<half> hazeMap [[texture(0)]]) {
        float aspect = u.size.x / max(u.size.y, 1.0f);
        float pixel = 1.0f / max(u.size.y, 1.0f);
        float pixel2 = 0.3f * pixel * pixel;
        float2 p = float2(in.uv.x * aspect, in.uv.y);
        float haze = u.motion.x;
        float glow = u.motion.w;

        half2 fogAndBillow = smoothSample(hazeMap, float2(in.uv.x, 1.0f - in.uv.y)); // textures run top-down
        float smoke = float(fogAndBillow.x), billow = float(fogAndBillow.y);
        float fill = u.floor.z;
        // Low contrast, like a room filled with fog: every beam shows along its
        // whole length and the volumes only thicken and thin it. Vocals and leads
        // thicken it further, so every beam glows fuller through it.
        float density = max(0.12f, 0.2f + 1.1f * smoke + 0.22f * (billow - 0.5f)) * (1.0f + 0.5f * fill);

        half3 light = 0;
        int count = int(u.size.z);
        bool nearTruss = p.y > 0.638f;
        for (int i = 0; i < 8; i++) {
            if (i >= count) break;
            float4 h = u.heads[i];
            float4 g = u.geometry[i];
            half3 color = half3(u.tints[i].rgb);
            float2 source = float2(g.x, 0.985f);
            light += beam(p, source, g.yz, h.z, h.y, color, density, glow, h.w, pixel, pixel2, haze, float(i) * 3.7f);
            if (nearTruss) {
                light += flare(p, source, h.y, color, glow);
            }
        }
        float floorLevel = u.size.w;
        if (floorLevel > 0.005f) {
            float2 rise = float2(u.floor.w, u.average.w); // up and in from the left corner
            half3 left = half3(u.floorColors[0].rgb), right = half3(u.floorColors[1].rgb);
            light += beam(p, float2(0.0f, 0.015f), rise, u.floor.y, floorLevel, left, density, glow, 0, pixel, pixel2, 0, 0);
            light += beam(p, float2(aspect, 0.015f), float2(-rise.x, rise.y), u.floor.y, floorLevel, right, density, glow, 0, pixel, pixel2, 0, 0);
            if (p.y < 0.365f) {
                light += flare(p, float2(0.01f, 0.015f), floorLevel, left, glow);
                light += flare(p, float2(aspect - 0.01f, 0.015f), floorLevel, right, glow);
            }
        }

        half3 average = half3(u.average.rgb);
        // A neutral cover gets crisper light on darker smoke: white beams read as stage light, not fog.
        half neutral = half(u.haze.w);
        light *= 1.0h + 0.12h * neutral;
        // Away from the beams the fog is barely there: a faint, broad glow.
        half hSmoke = fogAndBillow.x;
        half3 color = half3(0.01h, 0.011h, 0.016h) + average * hSmoke * 0.03h * (1.0h - 0.5h * neutral) + light;
        // Vocals and leads tint the fog with the cover's colour, in broad volumes only.
        color += half3(u.haze.rgb) * hSmoke * hSmoke * half(fill * 0.4f);
        // The opt-in strobe lights the whole haze, never more than three times a second.
        color += mix(average, half3(1.0h), 0.7h) * half(u.motion.z * (0.25f + 0.2f * density));
        color = 1.0h - exp2(color * (-1.15h * 1.442695h)); // highlights roll off toward white instead of clipping
        half alpha = clamp(0.86h + dot(color, half3(0.33h)) * 0.3h, 0.0h, 0.97h);
        return half4(color * alpha + dither(in.position.xy), alpha); // premultiplied, over the cover backdrop
    }
    """#
}
