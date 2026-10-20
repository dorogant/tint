/// Compiled with Metal at runtime so the CLT-only build needs no Metal compiler.
/// One library holds every live background; each gets its own pipeline, built once.
enum ReactiveShader {
    static let source = prelude + fluid + beams + bloom

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
    /// A Gaussian line profile pre-filtered for the pixel footprint: a line
    /// thinner than a pixel widens to one and dims to match, so its light is
    /// kept but it never breaks into stair steps.
    static float line(float across, float sigma, float pixel) {
        float s2 = sigma * sigma + 0.3 * pixel * pixel;
        return exp(-0.5 * across * across / s2) * sigma * rsqrt(s2);
    }
    /// Interleaved gradient noise, plus or minus half a code value, so dark
    /// gradients don't band in 8 bits.
    static float dither(float2 pixel) {
        return (fract(52.9829189 * fract(dot(pixel, float2(0.06711056, 0.00583715)))) - 0.5) / 255.0;
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
    /// current and merge where they meet. The bass breathes the field in from
    /// the centre, the glow swells on the brightest ink, the mids fill it out
    /// and the highs bring up its fine strands.
    private static let fluid = #"""
    // motion: flow clock, energy, glow, detail (highs). size: width, height, breath (bass), body (mids).
    struct FluidUniforms { float4 colors[5]; float4 motion; float4 size; };
    fragment float4 floeFluidFragment(Vertex in [[stage_in]], constant FluidUniforms& u [[buffer(0)]]) {
        float t = u.motion.x;
        float energy = u.motion.y;
        float glow = u.motion.z;
        float detail = u.motion.w;
        float body = u.size.w;
        float aspect = u.size.x / max(u.size.y, 1.0f);
        float2 middle = float2(0.5 * aspect, 0.5);
        float2 p = float2(in.uv.x * aspect, in.uv.y);

        // Breath: the whole field draws in toward the centre with the bass and eases back.
        p = middle + (p - middle) * (1 - 0.035 * u.size.z);

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
        float fill = smoothstep(0.06 - 0.03 * body, 0.9, field);
        float strands = fbm(w * 2.4 + curl * 1.6 - t * 0.04);
        // The highs sharpen the strands: more contrast between thread and gap.
        strands = mix(strands, smoothstep(0.3, 0.75, strands), 0.6 * detail);

        float3 color = ink * (0.055 + 0.06 * strands);
        color += ink * fill * (0.23 + 0.32 * strands) * (0.8 + 0.25 * energy + 0.2 * body);
        // The glow blooms out of the bright ink with energy and kicks.
        float bloom = glow / (1 + 0.35 * glow);
        float core = smoothstep(0.35, 1.3, field);
        color += ink * (core * 0.75 + min(halo, 1.5f) * 0.06) * bloom;
        color = limitLuma(color, 0.38, 0.6);
        float alpha = 0.9;
        return float4(min(color, 1.0f) * alpha + dither(in.position.xy), alpha); // premultiplied, over the cover backdrop
    }

    """#

    /// Moving heads on a truss along the top edge (and two from the floor on a
    /// drop) cut narrow cones through drifting haze, each with a hot core and a
    /// lens flare at its source, added together like real light. Everything
    /// else stays dark, so only the beams and flares are bright.
    private static let beams = #"""
    // motion: haze clock, spare, strobe flash, glow. size: width, height, heads, floor level.
    // floor: floor angle, floor spread, haze fill (mids), sin(floor angle). haze: haze colour, neutral cover.
    // heads: angle, intensity, spread, glint. tints: head colour, sin(angle). Beams point downward
    // (|angle| < pi/2), so the cosine is the positive root and nothing takes a sine per pixel.
    static float2 downward(float s) { return float2(s, -sqrt(max(0.0f, 1 - s * s))); }
    struct BeamUniforms {
        float4 colors[5]; float4 motion; float4 size; float4 floor; float4 haze;
        float4 floorColors[2]; float4 heads[8]; float4 tints[8];
    };
    /// Light scattered by the haze along one cone, brightest at its core. Every
    /// profile is pre-filtered for the pixel size, so thin beams stay smooth.
    static float3 beam(float2 p, float2 source, float2 dir, float spread, float intensity, float3 color,
                       float density, float glow, float glint, float pixel, float drift, float seed) {
        float2 v = p - source;
        float along = dot(v, dir);
        if (along <= 0 || intensity <= 0.001) return 0;
        float across = dot(v, float2(-dir.y, dir.x));
        float width = 0.006 + along * spread;
        if (abs(across) > width * 6 + 3 * pixel) return 0; // under a thousandth this far out
        float cone = line(across, width * 0.58, pixel) * (0.12 + 0.88 * density) * 0.75;
        float spill = exp(-0.08 * across * across / (width * width)) * 0.05 * glow * density;
        // Hats: motes inside the beam catch the light as they drift down it. They
        // live in the beam's own coordinates, so they move with it and never sit
        // on the screen, and only the core shows them.
        float motes = 0;
        if (glint > 0.01) {
            float n = noise(float2(along * 70 - drift * 4, across / width * 2.5 + seed));
            motes = smoothstep(0.7, 1.0, n) * glint;
        }
        float core = line(across, width * 0.17, pixel) * exp(-along * 1.6) * (1 + 0.6 * glint + 1.5 * motes);
        float falloff = 1 / (1 + along * along * 0.6);
        float start = smoothstep(0.0, 0.015, along); // fades in under the lens, no hard edge
        return (color * (cone + spill) + mix(color, float3(1), 0.6) * core * 0.6) * intensity * falloff * start;
    }
    /// The lens at a beam's source: a hot disk, a soft halo and a sideways streak.
    static float3 flare(float2 p, float2 source, float intensity, float3 color, float glow) {
        float2 d = p - source;
        float r2 = dot(d, d);
        if (r2 > 0.12) return 0; // the halo is under a thousandth this far out
        float disk = exp(-r2 * 1400);
        float streak = exp(-d.y * d.y * 3500 - abs(d.x) * 9) * 0.3;
        float halo = exp(-r2 * 45) * 0.16;
        return (mix(color, float3(1), 0.75) * (disk * 1.6 + streak) + color * halo) * intensity * (0.6 + 0.4 * glow);
    }
    /// Stage fog: large, soft volumes that drift sideways and slowly curl, with
    /// gentler billows inside them, and nothing smaller than a tenth of the
    /// screen, so it reads as smoke rather than smudges on the glass. It's all
    /// soft, so it's drawn at a quarter of the resolution and filtered up by the
    /// beams pass. Returns the fog's density and a billow term, both about 0…1.
    fragment float2 floeHazeFragment(Vertex in [[stage_in]], constant BeamUniforms& u [[buffer(0)]]) {
        float aspect = u.size.x / max(u.size.y, 1.0f);
        float2 p = float2(in.uv.x * aspect, in.uv.y);
        float t = u.motion.x;
        // A slow warp makes the volumes roll and curl instead of sliding as one.
        float2 warp = float2(fbm(p * 0.6 + float2(t * 0.03, 3.1)), fbm(p * 0.6 + float2(7.4, -t * 0.025)));
        float2 q = p + (warp - 0.5) * 0.9;
        float fog = fbm(q * float2(0.9, 1.3) + float2(t * 0.05, -t * 0.012));
        float billow = fbm(q * 1.6 + float2(-t * 0.08, t * 0.03) + warp * 1.5);
        return float2(fog, billow);
    }
    /// A B-spline filtered sample from four bilinear taps: upscaling the
    /// quarter-resolution fog by four leaves no diamonds or creases.
    static float4 smoothSample(texture2d<float> map, float2 uv) {
        constexpr sampler filtered(filter::linear, address::clamp_to_edge);
        float2 size = float2(map.get_width(), map.get_height());
        float2 st = uv * size - 0.5;
        float2 i = floor(st), f = st - i;
        float2 f2 = f * f, f3 = f2 * f;
        float2 w0 = (1 - 3 * f + 3 * f2 - f3) / 6, w1 = (4 - 6 * f2 + 3 * f3) / 6;
        float2 w2 = (1 + 3 * f + 3 * f2 - 3 * f3) / 6, w3 = f3 / 6;
        float2 g0 = w0 + w1, g1 = w2 + w3;
        float2 h0 = (i - 0.5 + w1 / g0) / size, h1 = (i + 1.5 + w3 / g1) / size;
        return g0.y * (g0.x * map.sample(filtered, float2(h0.x, h0.y)) + g1.x * map.sample(filtered, float2(h1.x, h0.y)))
             + g1.y * (g0.x * map.sample(filtered, float2(h0.x, h1.y)) + g1.x * map.sample(filtered, float2(h1.x, h1.y)));
    }
    fragment float4 floeBeamsFragment(Vertex in [[stage_in]], constant BeamUniforms& u [[buffer(0)]],
                                      texture2d<float> hazeMap [[texture(0)]]) {
        float aspect = u.size.x / max(u.size.y, 1.0f);
        float pixel = 1 / max(u.size.y, 1.0f);
        float2 p = float2(in.uv.x * aspect, in.uv.y);
        float haze = u.motion.x;
        float glow = u.motion.w;

        float2 fogAndBillow = smoothSample(hazeMap, float2(in.uv.x, 1 - in.uv.y)).xy; // textures run top-down
        float smoke = fogAndBillow.x, billow = fogAndBillow.y;
        float fill = u.floor.z;
        // Low contrast, like a room filled with fog: every beam shows along its
        // whole length and the volumes only thicken and thin it. Vocals and leads
        // thicken it further, so every beam glows fuller through it.
        float density = max(0.12f, 0.2 + 1.1 * smoke + 0.22 * (billow - 0.5)) * (1 + 0.5 * fill);

        float3 light = 0;
        int count = int(u.size.z);
        for (int i = 0; i < 8; i++) {
            if (i >= count) break;
            float4 h = u.heads[i];
            float3 color = u.tints[i].rgb;
            float2 source = float2((float(i) + 0.5) / float(count) * aspect, 0.985);
            light += beam(p, source, downward(u.tints[i].w), h.z, h.y, color, density, glow, h.w, pixel, haze, float(i) * 3.7);
            light += flare(p, source, h.y, color, glow);
        }
        float floorLevel = u.size.w;
        if (floorLevel > 0.005) {
            float2 rise = -downward(-u.floor.w); // up and in from the left corner
            float3 left = u.floorColors[0].rgb, right = u.floorColors[1].rgb;
            light += beam(p, float2(0, 0.015), rise, u.floor.y, floorLevel, left, density, glow, 0, pixel, 0, 0);
            light += beam(p, float2(aspect, 0.015), float2(-rise.x, rise.y), u.floor.y, floorLevel, right, density, glow, 0, pixel, 0, 0);
            light += flare(p, float2(0.01, 0.015), floorLevel, left, glow);
            light += flare(p, float2(aspect - 0.01, 0.015), floorLevel, right, glow);
        }

        float3 average = (u.colors[0].rgb + u.colors[1].rgb + u.colors[2].rgb + u.colors[3].rgb + u.colors[4].rgb) * 0.2;
        // A neutral cover gets crisper light on darker smoke: white beams read as stage light, not fog.
        float neutral = u.haze.w;
        light *= 1 + 0.12 * neutral;
        // Away from the beams the fog is barely there: a faint, broad glow.
        float3 color = float3(0.01, 0.011, 0.016) + average * smoke * 0.03 * (1 - 0.5 * neutral) + light;
        // Vocals and leads tint the fog with the cover's colour, in broad volumes only.
        color += u.haze.rgb * smoke * smoke * fill * 0.4;
        // The opt-in strobe lights the whole haze, never more than three times a second.
        color += mix(average, float3(1), 0.7) * u.motion.z * (0.25 + 0.2 * density);
        color = 1 - exp(-color * 1.15); // highlights roll off toward white instead of clipping
        float alpha = clamp(0.86 + dot(color, float3(0.33)) * 0.3, 0.0f, 0.97f);
        return float4(color * alpha + dither(in.position.xy), alpha); // premultiplied, over the cover backdrop
    }
    """#

    /// An endless dive into the Mandelbrot set, drawn by its distance estimate:
    /// the outline glows as thin filaments with a soft halo round them, and
    /// light pools in the bulbs, brightest at their centres. Far down,
    /// neighbouring pixels' c differ by far less than single precision can tell
    /// apart, so each pixel follows only its offset from one reference orbit
    /// (the copy's nucleus, periodic, so one period is all there is of it), and
    /// starts the reference over whenever its own orbit comes nearer 0 than the
    /// reference's (after Zhuoran).
    ///
    /// Iterating is costly and the dive slow, so each dive keeps a field of what
    /// it found per pixel (distance to the set, escape count) from frame to
    /// frame: each frame works out one block of pixels in 8 (or 16) afresh, in
    /// turn, and carries the rest over by the dive's own scale and turn between
    /// the two. A quarter-size pass tells how crowded the filaments are, and the
    /// light is made from the field and that every frame.
    private static let bloom = #"""
    // view: iterations, filament width (px), how far the next dive has faded in, spare.
    // size: width, height, where the dive heads (screen units: y runs −1…1, x the same times the aspect ratio).
    // light: glow, heart (mids), glint (hats, snares), beat. glints: where along the filaments they sit, spares, palette walk.
    // wave: drop ring radius, strength, level, bass.
    // Per dive. view: the pixel's offset from the reference's c is b + a·v at screen point v: a, then b.
    // counts: the reference's period, what brings escape counts to the whole set's, spares.
    // bulbs: the reference's c, and 1 over the scale its copy of the set is drawn at (complex). orbit: one period from 0.
    struct BloomLayer { float4 view; float4 counts; float4 bulbs; float2 orbit[64]; };
    struct BloomUniforms {
        float4 colors[5]; float4 view; float4 size; float4 light; float4 glints; float4 wave; BloomLayer layers[2];
    };
    // The field pass for one dive: which layer, which of `turns` sets of blocks is
    // worked out afresh (all of them when `all`), and where screen point v was
    // last frame: history.xy + history.zw·v (complex).
    struct BloomPass { int layer; int phase; int all; int turns; float4 history; };
    /// Each 4×4 group of blocks in the order they're worked out, so the blocks
    /// done together are spread out.
    constant int blockOrder[16] = {0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5};
    static float2 complexMultiply(float2 a, float2 b) { return float2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x); }
    /// The palette as a loop, eased from colour to colour.
    static float3 paletteLoop(constant float4 *colors, float t) {
        t = fract(t) * 5;
        int i = int(t);
        float f = t - float(i);
        f = f * f * (3 - 2 * f);
        return mix(colors[i % 5].rgb, colors[(i + 1) % 5].rgb, f);
    }
    /// A palette colour as light: dark slots are lifted to full strength, so a
    /// navy reads as blue neon rather than mud. Greys stay grey.
    static float3 lightTint(constant float4 *colors, float t) {
        float3 c = paletteLoop(colors, t);
        return c / max(max(c.r, max(c.g, c.b)), 0.08f);
    }
    static float2 complexSqrt(float2 w) {
        float r = length(w);
        float2 root = float2(sqrt(max(0.0f, 0.5f * (r + w.x))), sqrt(max(0.0f, 0.5f * (r - w.x))));
        return float2(root.x, w.y < 0 ? -root.y : root.y);
    }
    /// How long an orbit from c takes to settle (as `bloomPoint` counts it),
    /// if c is in the set's main cardioid or its period-2 bulb, where the
    /// cycle's multiplier λ is known outright; else −1. `firm` is how far below
    /// 1 |λ| must be to count. The biggest bulbs are where orbits take longest
    /// to settle, so this spares most of their iterating.
    static float knownBulb(float2 c, float steps, float firm) {
        float cardioid = length(float2(1, 0) - complexSqrt(float2(1, 0) - 4 * c));
        float bulb = 4 * length(c + float2(1, 0));
        if (cardioid < firm) return 11.513f * steps / -log(max(cardioid, 1e-6f));
        if (bulb < firm) return 11.513f * 2 * steps / -log(max(bulb, 1e-6f));
        return -1;
    }
    /// What one dive finds at screen point `v`: outside the set, the distance
    /// to it in pixels and the smooth escape count; inside, −1 less how long its
    /// orbit takes to settle onto its cycle, in the whole set's steps. Then 0, 1.
    static float4 bloomPoint(constant BloomUniforms& u, constant BloomLayer& l, float2 v) {
        float2 a = l.view.xy, dc = l.view.zw + complexMultiply(a, v);
        int period = int(l.counts.x), n = 0;
        float pixel = 2 / max(u.size.y, 1.0f), scale = l.counts.y;
        // In the whole set's big bulbs, or its copy's (seen through the map
        // that takes the set to the copy, close enough well inside them).
        float known = knownBulb(l.bulbs.xy + dc, 1, 1);
        if (known < 0) known = knownBulb(complexMultiply(dc, l.bulbs.zw), float(period), 0.9);
        if (known >= 0) return float4(-1 - min(known, 1e4f) * scale, 0, 0, 1);
        // z is the orbit, d its offset from the reference; dz its derivative
        // across the screen, dZ across the orbit's own start, which shrinks
        // only for an orbit settling onto a bulb's cycle.
        float2 d = 0, z = 0, dz = 0, dZ = float2(1, 0);
        // Brent's check for a cycle: the orbit at the last checkpoint, kept as
        // its offset and where the reference was, so the two compare exactly
        // however deep the dive. Back within a hundredth of a pixel's worth,
        // it has settled; how fast dZ shrank since says how firmly.
        float2 saved = 0;
        int savedN = -1, savedI = 0, checkpoint = 4;
        float savedM = 1, near = 1e-4 * pixel * pixel;
        // 0: still going (on the set's edge), 1: escaped, 2: settled in a bulb.
        int state = 0, i = 0, limit = int(u.view.x);
        float r2 = 0, settled = 0;
        for (; i < limit; i++) {
            dz = 2 * complexMultiply(z, dz) + a;
            if (i > 0) dZ = 2 * complexMultiply(z, dZ);
            d = complexMultiply(2 * l.orbit[n] + d, d) + dc;
            n = n + 1 == period ? 0 : n + 1;
            z = l.orbit[n] + d;
            r2 = dot(z, z);
            if (r2 > 1024) { state = 1; break; }
            if (r2 < dot(d, d)) { d = z; n = 0; }
            float m = dot(dZ, dZ);
            if (m < 1e-30) { state = 2; break; } // a bulb's very centre
            if (n == savedN && distance_squared(d, saved) < near * dot(dz, dz)) {
                // Steps for dZ to shrink by 10⁵ at the rate it has: 0 at a bulb's
                // centre, rising smoothly without bound toward its rim.
                float rate = log(m / savedM) / float(i - savedI);
                if (rate < -1e-4) { settled = min(-23.03f / rate, 1e4f); state = 2; break; }
            }
            if (i == checkpoint) { saved = d; savedN = n; savedI = i; savedM = m; checkpoint *= 2; }
        }
        // An orbit still going that has stopped stretching is at a bulb's rim, settling slowly.
        if (state == 0 && dot(dz, dz) < 1e6) { state = 2; settled = 1e4; }
        if (state == 2) return float4(-1 - settled * scale, 0, 0, 1);
        // Distance to the set in pixels (dz is per screen unit). An orbit still
        // going hasn't escaped to measure from; how hard it is still stretching
        // stands in, and it only glows faintly, as if a little way off the edge:
        // deep down whole stretches never escape in time, and they mustn't blaze.
        float lr = 0.5 * log(max(r2, 1.0001f));
        float stretch = rsqrt(max(dot(dz, dz), 1e-30f));
        float px = state == 1 ? sqrt(r2) * lr * stretch / pixel : max(stretch / pixel, 3.0f);
        // The smooth escape time, brought to the whole set's so the colours run
        // on unbroken as the dive deepens and one dive hands to the next.
        float mu = (float(i + 1) - log2(max(lr, 1e-4f))) * scale;
        return float4(min(px, 1e4f), mu, 0, 1);
    }
    fragment float4 floeBloomField(Vertex in [[stage_in]], constant BloomUniforms& u [[buffer(0)]],
                                   constant BloomPass& pass [[buffer(1)]], texture2d<float, access::read> last [[texture(0)]]) {
        uint2 pixel = uint2(in.position.xy);
        float aspect = u.size.x / max(u.size.y, 1.0f);
        float2 v = float2((in.uv.x * 2 - 1) * aspect, in.uv.y * 2 - 1);
        // Whole 8×8 blocks at a time, so pixels shaded together either all iterate or all carry over.
        uint2 block = pixel / 8;
        bool afresh = pass.all != 0 || blockOrder[(block.x & 3) + 4 * (block.y & 3)] * pass.turns / 16 == pass.phase;
        // Last frame's field where this point was, between its four nearest
        // pixels; across the set's edge, the nearest alone.
        if (!afresh) {
            float2 was = pass.history.xy + complexMultiply(pass.history.zw, v);
            float2 at = float2((was.x / aspect + 1) * 0.5 * u.size.x, (1 - was.y) * 0.5 * u.size.y) - 0.5;
            float2 size = float2(last.get_width(), last.get_height());
            if (all(at >= 0) && all(at <= size - 1)) {
                uint2 corner = uint2(min(floor(at), size - 2));
                float2 f = at - float2(corner);
                float4 a = last.read(corner), b = last.read(corner + uint2(1, 0));
                float4 c = last.read(corner + uint2(0, 1)), d = last.read(corner + uint2(1, 1));
                bool inside = a.x < 0;
                if (inside == (b.x < 0) && inside == (c.x < 0) && inside == (d.x < 0))
                    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
                return f.y < 0.5 ? (f.x < 0.5 ? a : b) : (f.x < 0.5 ? c : d);
            }
        }
        return bloomPoint(u, u.layers[pass.layer], v);
    }
    /// How crowded each dive's filaments are round every 4×4 pixels (the share
    /// of them on a filament's core), and the colour coordinate there (the mean
    /// escape count outside the set). It's drawn at a quarter of the resolution
    /// and filtered up, so both stay smooth where filaments are finer than a
    /// pixel and their escape counts jump from one pixel to the next.
    fragment float4 floeBloomCrowd(Vertex in [[stage_in]], texture2d<float, access::read> current [[texture(0)]],
                                   texture2d<float, access::read> incoming [[texture(1)]]) {
        uint2 corner = uint2(in.position.xy) * 4;
        uint2 limit = uint2(current.get_width(), current.get_height()) - 1;
        float2 lit = 0, counts = 0, outside = 0;
        for (uint y = 0; y < 4; y++) {
            for (uint x = 0; x < 4; x++) {
                uint2 at = min(corner + uint2(x, y), limit);
                float2 a = current.read(at).xy, b = incoming.read(at).xy;
                float2 px = float2(a.x, b.x);
                bool2 out = px >= 0;
                lit += select(float2(0), exp(-0.5 * px * px / 2.25), out);
                counts += select(float2(0), float2(a.y, b.y), out);
                outside += select(float2(0), float2(1), out);
            }
        }
        return float4(lit / 16, counts / max(outside, 1.0f));
    }
    /// One dive's light at `pixel` (screen point `v`), from its field and how
    /// crowded its filaments are there. Where they crowd closer than a pixel
    /// can follow, they're drawn as the even glow they average to, and dimmer,
    /// so a dense stretch is neither a wall of light nor a shimmer of specks.
    static float3 bloomLight(constant BloomUniforms& u, texture2d<float, access::read> fields, uint2 pixel, float2 v,
                             float crowd, float count) {
        float4 field = fields.read(pixel);
        float even = 0.6 * smoothstep(0.25, 0.75, crowd);
        float spread = 1 / (1 + 6 * crowd * crowd * crowd * crowd);
        // The cover's colours lie round the dive's centre, so each side of it takes its own.
        float2 from = v - u.size.zw;
        float around = atan2(from.y, from.x) * 0.15915494;
        float glow = u.light.x * (0.8 + 0.4 * u.wave.w), heart = u.light.y, hue = u.glints.w;
        bool inside = field.x < 0;
        float px = max(field.x, 0.0f);
        float3 tint = lightTint(u.colors, hue + around + 0.01 * count);
        float width = u.view.y;
        // Halos overlap where filaments crowd, so there each is fainter.
        float halo = (exp(-px / (4 + 6 * glow)) * 0.45 + 0.04 / (1 + 0.025 * px)) * sqrt(glow) / (1 + 2 * crowd * glow);
        float3 light;
        if (!inside) {
            float core = exp(-0.5 * px * px / (width * width));
            light = ((tint * 1.2 + 0.45 * spread) * core + tint * halo) * spread;
            // Hats and snares: short glints on the filaments, in bands of the
            // escape count that move on with each one, so they run along the outline.
            if (u.light.z > 0.01) {
                float bands = smoothstep(0.75, 1.0, sin(count * 0.35 - u.glints.x * 6.2831853));
                float on = mix(exp(-0.5 * px * px / 4), crowd, even);
                light += mix(paletteLoop(u.colors, hue + 0.25), float3(1), 0.5) * bands * on * u.light.z * 0.5 * spread;
            }
        } else {
            // Quick to settle at a bulb's centre, slower toward its rim: the
            // light falls off with that alone.
            float pool = exp(-0.035 * (-1 - field.x));
            light = lightTint(u.colors, hue + 0.45 + around) * (0.006 + 0.01 * heart + pool * (0.03 + 0.3 * heart));
        }
        // Where filaments crowd, every pixel, in a speck of a bulb or between
        // filaments, takes the even glow they average to.
        if (even > 0) light = mix(light, ((tint * 1.2 + 0.45 * spread) * crowd + tint * 0.4 * sqrt(glow) / (1 + 2 * crowd * glow)) * spread, even);
        return light;
    }
    fragment float4 floeBloomFragment(Vertex in [[stage_in]], constant BloomUniforms& u [[buffer(0)]],
                                      texture2d<float, access::read> current [[texture(0)]],
                                      texture2d<float, access::read> incoming [[texture(1)]],
                                      texture2d<float> crowds [[texture(2)]]) {
        uint2 pixel = uint2(in.position.xy);
        float aspect = u.size.x / max(u.size.y, 1.0f);
        float2 v = float2((in.uv.x * 2 - 1) * aspect, in.uv.y * 2 - 1);
        float4 crowd = smoothSample(crowds, float2(in.uv.x, 1 - in.uv.y)); // textures run top-down
        float3 light = bloomLight(u, current, pixel, v, crowd.x, crowd.z);
        // The next dive fades in over this one's last stretch: both dive on together meanwhile.
        if (u.view.z > 0) light = mix(light, bloomLight(u, incoming, pixel, v, crowd.y, crowd.w), u.view.z);
        // The drop's single wave runs out from the dive's centre, lighting the filaments it passes.
        float wave = exp(-pow((length(v - u.size.zw) - u.wave.x) / 0.25, 2.0f)) * u.wave.y;
        float level = u.wave.z * (1 + 0.15 * u.light.w) * (1 + 3 * wave);
        light *= level;
        light += lightTint(u.colors, u.glints.w + atan2(v.y - u.size.w, v.x - u.size.z) * 0.15915494) * wave * 0.05;

        float3 average = (u.colors[0].rgb + u.colors[1].rgb + u.colors[2].rgb + u.colors[3].rgb + u.colors[4].rgb) * 0.2;
        float3 color = float3(0.008, 0.009, 0.013) + average * 0.02 + light;
        color = 1 - exp(-color * 1.2); // highlights roll off instead of clipping
        color = limitLuma(color, 0.38, 0.6);
        float alpha = 0.92;
        return float4(color * alpha + dither(in.position.xy), alpha); // premultiplied, over the cover backdrop
    }
    """#
}
