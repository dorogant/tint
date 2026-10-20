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

    /// An endless dive into the Mandelbrot set, coloured the classic way: each
    /// pixel outside the set takes the cover's colours by its smooth escape
    /// count, so the bands run in unbroken gradients and crowd ever tighter
    /// toward the set, lit by the slope the distance estimate gives them, with
    /// the outline itself drawn as fine light filaments. The set's inside is
    /// dark. Far down, neighbouring pixels' c differ by far less than single
    /// precision can tell apart, so each pixel follows only its offset from one
    /// reference orbit (the copy's nucleus, periodic, so one period is all there
    /// is of it), and starts the reference over whenever its own orbit comes
    /// nearer 0 than the reference's (after Zhuoran).
    ///
    /// Every pixel is worked out afresh every frame, nothing carried over, into
    /// a field at about a pixel per point (or fewer on a big screen): distance
    /// to the set, escape count, which way the set lies. The colour is made
    /// from it at the screen's own resolution; each field pixel knows where the
    /// outline nearest it runs, so the filaments and the set's edge are drawn
    /// as sharp as the screen can show them.
    private static let bloom = #"""
    // view: iterations, filament width (screen pixels), how far the next dive has faded in, spare.
    // size: drawable width, height, where the dive heads (screen units: y runs −1…1, x the same times the aspect ratio).
    // light: glow, heart (mids), glint (hats, snares), beat. glints: where along the bands they sit, spares, palette walk.
    // wave: drop ring radius, strength, level, bass.
    // Per dive. view: the pixel's offset from the reference's c is b + a·v at screen point v: a, then b.
    // counts: the reference's period, what brings escape counts to the whole set's, spares.
    // bulbs: the reference's c, and 1 over the scale its copy of the set is drawn at (complex). orbit: one period from 0.
    struct BloomLayer { float4 view; float4 counts; float4 bulbs; float2 orbit[64]; };
    struct BloomUniforms {
        float4 colors[5]; float4 view; float4 size; float4 light; float4 glints; float4 wave; BloomLayer layers[2];
    };
    // The field pass for one dive: which of the uniforms' layers, and how far apart its pixels are in screen units.
    struct BloomPass { int layer; float pixel; };
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
    /// Whether c lies in the set's main cardioid or its period-2 bulb, where
    /// the cycle's multiplier is known outright, at least `firm` below 1. The
    /// biggest bulbs are where orbits take longest to settle, so this spares
    /// most of their iterating.
    static bool knownBulb(float2 c, float firm) {
        return length(float2(1, 0) - complexSqrt(float2(1, 0) - 4 * c)) < firm || 4 * length(c + float2(1, 0)) < firm;
    }
    /// What one dive finds at screen point `v`, `pixel` screen units apart:
    /// outside the set, the distance to it in pixels, the smooth escape count
    /// (in the whole set's steps) and which way the set lies (a unit step in
    /// pixels, y down; 0 where that's unknown); inside, −1 and 0s.
    static float4 bloomPoint(constant BloomUniforms& u, constant BloomLayer& l, float2 v, float pixel) {
        float2 a = l.view.xy, dc = l.view.zw + complexMultiply(a, v);
        int period = int(l.counts.x), n = 0;
        // In the whole set's big bulbs, or its copy's (seen through the map
        // that takes the set to the copy, close enough well inside them).
        if (knownBulb(l.bulbs.xy + dc, 1) || knownBulb(complexMultiply(dc, l.bulbs.zw), 0.9)) return float4(-1, 0, 0, 0);
        // z is the orbit, d its offset from the reference orbit, whose step it's
        // at is Z; dz the orbit's derivative across the screen.
        float2 d = 0, z = 0, dz = 0, Z = l.orbit[0];
        // Brent's check for a cycle: the orbit and its derivative at the last
        // checkpoint, kept as the offset and where the reference was, so the
        // two compare exactly however deep the dive. Back within 1e-5 with its
        // derivative no longer growing, it has settled in a bulb; an orbit on
        // its way out keeps stretching, so never counts. Every eighth step is
        // enough to catch it, at an eighth of the cost.
        float2 saved = 0, savedDz = 0;
        int savedN = -1, checkpoint = 8;
        int i = 0, limit = int(u.view.x);
        float r2 = 0;
        bool settled = false;
        for (; i < limit; i++) {
            dz = 2 * complexMultiply(z, dz) + a;
            d = complexMultiply(2 * Z + d, d) + dc;
            n = n + 1 == period ? 0 : n + 1;
            Z = l.orbit[n];
            z = Z + d;
            r2 = dot(z, z);
            if (r2 < dot(d, d)) { d = z; n = 0; Z = 0; }
            if (r2 > 1e4) break;
            if ((i & 7) == 0) {
                settled = n == savedN && distance_squared(d, saved) < 1e-10 && distance_squared(dz, savedDz) < 1e-4 * dot(dz, dz);
                if (settled) break;
                if (i >= checkpoint) { saved = d; savedDz = dz; savedN = n; checkpoint *= 2; }
            }
        }
        if (settled) return float4(-1, 0, 0, 0);
        // Neither out nor settled: so close to the outline that it's on it.
        if (i == limit) return float4(0, float(limit) * l.counts.y, 0, 0);
        // Distance to the set in pixels (dz is per screen unit), from the potential and its slope.
        float lr = 0.5 * log(r2);
        float stretch = rsqrt(max(dot(dz, dz), 1e-30f));
        float px = sqrt(r2) * lr * stretch / pixel;
        // The smooth escape count, brought to the whole set's so the colours run
        // on unbroken as the dive deepens and one dive hands to the next.
        float mu = (float(i + 1) - log2(max(lr, 1e-4f))) * l.counts.y;
        // Which way the set lies: down the potential's slope, whose gradient is
        // conj(dz/z) in screen units (y up).
        float2 g = complexMultiply(z, float2(dz.x, -dz.y) * stretch);
        float slope = length(g);
        float2 toward = slope > 0 && isfinite(slope) ? float2(-g.x, g.y) / slope : float2(0);
        return float4(min(px, 1e4f), mu, toward);
    }
    fragment float4 floeBloomField(Vertex in [[stage_in]], constant BloomUniforms& u [[buffer(0)]],
                                   constant BloomPass& pass [[buffer(1)]]) {
        float aspect = u.size.x / max(u.size.y, 1.0f);
        float2 v = float2((in.uv.x * 2 - 1) * aspect, in.uv.y * 2 - 1);
        return bloomPoint(u, u.layers[pass.layer], v, pass.pixel);
    }
    /// A dive's field read between its pixels' centres, at `q` (in its pixels),
    /// from the four round it. Each outside pixel knows how far off the
    /// outline nearest it runs and which way, so it tells how far that outline
    /// runs from q as well, as if straight across. So a filament between pixels
    /// stays as sharp as it is wherever it falls, and carried from frame to
    /// frame it neither blurs nor wanders. `side` is below 0 inside the set,
    /// `inside` the inside pixels' share of q.
    struct BloomSample { float distance; float spread; float count; float2 toward; float side; float settle; float inside; float sure; };
    static BloomSample bloomRead(texture2d<float, access::read> field, float2 q) {
        float2 size = float2(field.get_width(), field.get_height());
        q = clamp(q, float2(0), size - 1);
        float2 corner = min(floor(q), max(size - 2, float2(0)));
        float2 f = q - corner;
        uint2 c = uint2(corner);
        float4 t0 = field.read(c), t1 = field.read(c + uint2(1, 0)), t2 = field.read(c + uint2(0, 1)), t3 = field.read(c + uint2(1, 1));
        float4 x = float4(t0.x, t1.x, t2.x, t3.x);
        float4 nx = float4(t0.z, t1.z, t2.z, t3.z), ny = float4(t0.w, t1.w, t2.w, t3.w);
        // Each pixel's offset to q, its share of q, and how far it says its outline runs from q.
        float4 ox = float4(f.x, f.x - 1, f.x, f.x - 1), oy = float4(f.y, f.y, f.y - 1, f.y - 1);
        float4 w = float4(1 - f.x, f.x, 1 - f.x, f.x) * float4(1 - f.y, 1 - f.y, f.y, f.y);
        float4 e = x - (nx * ox + ny * oy);
        bool4 out = x >= 0;
        float4 shares = select(float4(0), w, out);
        float outside = shares.x + shares.y + shares.z + shares.w, inside = 1 - outside;
        BloomSample s;
        // Where the pixels agree on one outline (or know none) this is plain
        // interpolation; across a filament it keeps its sharp crease.
        // A few pixels off, the estimate is smooth but no exact distance:
        // there plain interpolation, which leaves no trace of the pixels.
        float plain = dot(shares, x) / max(outside, 1e-6f), far = smoothstep(2.0f, 4.0f, plain);
        s.distance = outside > 0 ? mix(dot(shares, abs(e)) / outside, plain, far) : 1e4;
        // Where they disagree, filaments run finer than the pixels can tell apart.
        s.spread = (1 - far) * dot(shares, abs(abs(e) - s.distance)) / max(outside, 1e-6f);
        s.count = dot(shares, float4(t0.y, t1.y, t2.y, t3.y)) / max(outside, 1e-6f);
        s.inside = inside;
        s.settle = dot(w - shares, x) / max(inside, 1e-6f);
        // Which way the set lies, as the pixels agree on it; past an outline the
        // set lies back the other way. Where filaments are finer than the
        // pixels they don't agree, and it's no way in particular.
        float4 flip = select(float4(1), float4(-1), e < 0) * shares;
        s.toward = (flip.x * t0.zw + flip.y * t1.zw + flip.z * t2.zw + flip.w * t3.zw) / max(outside, 1e-6f);
        // Inside the set or not: each pixel votes half a pixel's worth for its
        // own side, so the edge falls halfway between, unless outside pixels
        // near it know where their outline runs; then it falls there, between
        // pixels, the inside ones agreeing.
        s.sure = 0;
        s.side = 0;
        if (inside <= 0) return s;
        float4 sure = select(float4(0), saturate(nx * nx + ny * ny) * saturate(2 - x), out);
        float4 votes = mix(float4(0.5), clamp(e, -0.5f, 0.5f), sure);
        float known = dot(shares, sure);
        float line = known > 0 ? clamp(dot(shares * sure, e) / known, -0.5f, -0.02f) : -0.5f;
        s.sure = known / max(outside, 1e-6f);
        s.side = dot(shares, votes) + inside * mix(-0.5f, line, s.sure);
        return s;
    }
    /// One dive's colour at screen pixel `uv` (screen point `v`), from its
    /// field read there, `scale` screen pixels to a field pixel.
    static float3 bloomColor(constant BloomUniforms& u, texture2d<float, access::read> field, float2 uv, float2 v, float scale) {
        float2 size = float2(field.get_width(), field.get_height());
        BloomSample s = bloomRead(field, uv * size - 0.5);
        float glow = u.light.x * (0.8 + 0.4 * u.wave.w), heart = u.light.y, hue = u.glints.w;
        float2 from = v - u.size.zw;
        float around = atan2(from.y, from.x) * 0.15915494;
        // The bands: the cover's colours by the escape count's square root, so
        // they widen out into slow gradients far from the set and crowd into
        // fine rings close to it.
        float m = max(s.count, 1.0f);
        float bands = sqrt(m) * 0.25;
        // How many times round the palette the bands go within a field pixel:
        // the escape count's slope is 1 over ln 2 times the distance to the
        // set. Where that's more than the field can follow, the bands blend
        // into the colour they average to rather than breaking into noise.
        float density = 0.25 / (2 * sqrt(m) * 0.6931 * max(s.distance, 1e-3f));
        float blend = smoothstep(0.1, 0.35, density);
        float3 mean = (u.colors[0].rgb + u.colors[1].rgb + u.colors[2].rgb + u.colors[3].rgb + u.colors[4].rgb) * 0.2;
        float3 tint = mix(paletteLoop(u.colors, hue + bands + 0.05 * around), mean, blend);
        // Far from the set the ground is dim; it brightens toward the set's
        // structure, where the bands crowd.
        float near = exp(-s.distance / (60.0 / scale));
        float3 color = tint * (0.12 + 0.5 * near);
        // Lit from the upper left along the slope toward the set, so the
        // structure stands out in relief, where the field can tell its slope.
        color *= 1 + 0.35 * (1 - blend) * dot(s.toward, float2(0.7071, 0.7071));
        // Hats and snares: glints in bands of the escape count that move on with each one.
        if (u.light.z > 0.01) color += tint * smoothstep(0.75, 1.0, sin(m * 0.35 - u.glints.x * 6.2831853)) * u.light.z * 0.25 * near;
        // The outline as fine light filaments at the screen's own pixels,
        // pre-filtered so one thinner than a pixel dims rather than breaking up.
        float across = s.distance * scale, width = u.view.y, footprint = width * width + 0.3;
        float core = exp(-0.5 * across * across / footprint) * width * rsqrt(footprint);
        // Where filaments run finer than the field can tell apart, the even
        // glow they'd average to instead.
        float tangle = smoothstep(0.15f, 0.5f, s.spread);
        core = mix(core, 0.3 * near, tangle);
        color += mix(lightTint(u.colors, hue + 0.05 * around), float3(1), 0.4) * core * 0.6 * sqrt(glow);
        // Inside, dark, with a faint pool of light that the mids bring up.
        float cover = smoothstep(0.5f, -0.5f, s.side * mix(1.0f, scale, s.sure)) * min(1.0f, 4 * s.inside);
        if (cover > 0) {
            // A speck of the set a pixel or two across is too small to show as
            // dark: its outline glows there instead.
            int2 at = int2(round(uv * size - 0.5)), last = int2(size) - 1;
            float within = 0;
            for (int dy = -1; dy <= 1; dy++)
                for (int dx = -1; dx <= 1; dx++)
                    within += field.read(uint2(clamp(at + int2(dx, dy), int2(0), last))).x < 0 ? 1 : 0;
            cover *= smoothstep(2.5f, 5.5f, within);
            color = mix(color, lightTint(u.colors, hue + 0.45 + around) * (0.008 + 0.03 * heart), cover);
        }
        return color;
    }
    fragment float4 floeBloomFragment(Vertex in [[stage_in]], constant BloomUniforms& u [[buffer(0)]],
                                      texture2d<float, access::read> current [[texture(0)]],
                                      texture2d<float, access::read> incoming [[texture(1)]]) {
        float aspect = u.size.x / max(u.size.y, 1.0f);
        float2 v = float2((in.uv.x * 2 - 1) * aspect, in.uv.y * 2 - 1);
        float2 uv = float2(in.uv.x, 1 - in.uv.y); // textures run top-down
        float scale = u.size.y / float(current.get_height());
        float3 light = bloomColor(u, current, uv, v, scale);
        // The next dive fades in over this one's last stretch: both dive on together meanwhile.
        if (u.view.z > 0) light = mix(light, bloomColor(u, incoming, uv, v, scale), u.view.z);
        // The drop's single wave runs out from the dive's centre, lighting what it passes.
        float wave = exp(-pow((length(v - u.size.zw) - u.wave.x) / 0.25, 2.0f)) * u.wave.y;
        light *= u.wave.z * (1 + 0.15 * u.light.w) * (1 + 3 * wave);
        float3 color = float3(0.008, 0.009, 0.013) + light;
        color = 1 - exp(-color * 1.2); // highlights roll off instead of clipping
        color = limitLuma(color, 0.38, 0.6);
        float alpha = 0.92;
        return float4(color * alpha + dither(in.position.xy), alpha); // premultiplied, over the cover backdrop
    }
    """#
}
