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
    static float2 smoothSample(texture2d<float> map, float2 uv) {
        constexpr sampler filtered(filter::linear, address::clamp_to_edge);
        float2 size = float2(map.get_width(), map.get_height());
        float2 st = uv * size - 0.5;
        float2 i = floor(st), f = st - i;
        float2 f2 = f * f, f3 = f2 * f;
        float2 w0 = (1 - 3 * f + 3 * f2 - f3) / 6, w1 = (4 - 6 * f2 + 3 * f3) / 6;
        float2 w2 = (1 + 3 * f + 3 * f2 - 3 * f3) / 6, w3 = f3 / 6;
        float2 g0 = w0 + w1, g1 = w2 + w3;
        float2 h0 = (i - 0.5 + w1 / g0) / size, h1 = (i + 1.5 + w3 / g1) / size;
        return g0.y * (g0.x * map.sample(filtered, float2(h0.x, h0.y)).rg + g1.x * map.sample(filtered, float2(h1.x, h0.y)).rg)
             + g1.y * (g0.x * map.sample(filtered, float2(h0.x, h1.y)).rg + g1.x * map.sample(filtered, float2(h1.x, h1.y)).rg);
    }
    fragment float4 floeBeamsFragment(Vertex in [[stage_in]], constant BeamUniforms& u [[buffer(0)]],
                                      texture2d<float> hazeMap [[texture(0)]]) {
        float aspect = u.size.x / max(u.size.y, 1.0f);
        float pixel = 1 / max(u.size.y, 1.0f);
        float2 p = float2(in.uv.x * aspect, in.uv.y);
        float haze = u.motion.x;
        float glow = u.motion.w;

        float2 fogAndBillow = smoothSample(hazeMap, float2(in.uv.x, 1 - in.uv.y)); // textures run top-down
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

    /// A Julia set drawn by its distance estimate: the outline glows as thin
    /// filaments with a soft halo in the water around them. Inside, light pools
    /// toward the centre of every bulb, measured by the set's own conformal
    /// coordinate (Koenigs'), and the heart's light (the mids) fills it; outside,
    /// the escape time draws faint equipotential ripples. Orbits passing the hat
    /// constellation glint. Each frame is kept, fading, in a second target, so
    /// dust a kick scatters leaves trails.
    private static let bloom = #"""
    // c: c, then the plane per screen half-height (a complex scale and turn). view: centre, iterations, filament width (px).
    // size: width, height, trail fade, trail drift. light: glow, heart (mids), glint (hats), beat.
    // traps: constellation turn (cos, sin), radius, palette walk. wave: drop ring radius, strength, level, spare.
    // flags: no trails yet, detail (highs), log of the fixed point's multiplier |λ|, its turn θ.
    // previous: the trails' centre and span, as drawn last frame.
    // Screen units below: y runs −1…1 and x the same times the aspect ratio, as `v` does.
    // kicks: per kick, its epicentre, reach and shatter. twist: the snare's point, angle and reach.
    // places: where the drop's wave sets out, where the vocals' light pools.
    struct BloomUniforms {
        float4 colors[5]; float4 c; float4 view; float4 size; float4 light; float4 traps; float4 wave; float4 flags;
        float4 previous; float4 kicks[3]; float4 twist; float4 places;
    };
    struct BloomOutput { float4 color [[color(0)]]; float4 trails [[color(1)]]; };
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
    /// Anti-aliased lines at the integers of `x`, faded out where they crowd
    /// closer than a few pixels. Works across a wrap of `x` by a whole number.
    static float contour(float x, float sharpness) {
        float width = min(fwidth(x), fwidth(fract(x + 0.5)));
        float across = abs(fract(x + 0.5) - 0.5);
        float line = 1 - smoothstep(0.0, 1.2 * width + 0.02 / sharpness, across);
        return line * (1 - smoothstep(0.08, 0.3, width));
    }
    fragment BloomOutput floeBloomFragment(Vertex in [[stage_in]], constant BloomUniforms& u [[buffer(0)]],
                                           texture2d<float> trails [[texture(0)]]) {
        float aspect = u.size.x / max(u.size.y, 1.0f);
        float2 v = float2((in.uv.x * 2 - 1) * aspect, in.uv.y * 2 - 1);
        float2 axis = u.c.zw;
        // The snare turns the plane round its own point, less the further from it.
        float2 fromTwist = v - u.twist.xy;
        float twistAngle = u.twist.z * exp(-dot(fromTwist, fromTwist) / (u.twist.w * u.twist.w));
        float2 twisted = u.twist.xy + complexMultiply(fromTwist, float2(cos(twistAngle), sin(twistAngle)));
        float2 z = u.view.xy + complexMultiply(axis, twisted);
        float2 point = z;
        // The cover's colours lie round the set, so each side of it takes its own.
        float around = atan2(z.y, z.x) * 0.15915494;
        float pixel = 2 * length(axis) / max(u.size.y, 1.0f);
        // Each kick throws the shape out past the edge around its epicentre, fading
        // with distance, so a patch of the set shatters while the rest holds.
        float shatter = 0, kicked = 0;
        for (int k = 0; k < 3; k++) {
            float2 d = v - u.kicks[k].xy;
            float weight = exp(-dot(d, d) / (u.kicks[k].z * u.kicks[k].z));
            shatter += u.kicks[k].w * weight;
            kicked = max(kicked, weight * min(1.0f, abs(u.kicks[k].w) * 30));
        }
        float logRho = log(max(0.5f, exp(u.flags.z) + shatter)), theta = u.flags.w;
        float2 lambdaHere = exp(logRho) * float2(cos(theta), sin(theta));
        float2 c = 0.5 * lambdaHere - 0.25 * complexMultiply(lambdaHere, lambdaHere);
        float2 fixed = 0.5 * lambdaHere; // α, whose multiplier is λ = 2α
        // Inside the cardioid every orbit in the heart settles onto α: stop once it's close.
        float settle = logRho < -0.004 ? 0.0036 : -1.0;
        float2 dz = float2(1, 0);
        float r2 = dot(z, z);
        // Hats: three trap points turning round the origin.
        float2 t0 = u.traps.xy * u.traps.z;
        float2 t1 = complexMultiply(t0, float2(-0.5, 0.8660254));
        float2 t2 = complexMultiply(t0, float2(-0.5, -0.8660254));
        float trap = 1e4;
        int n = int(u.view.z);
        int i = 0;
        int state = 0; // 0: still going (on the set's edge, or dust), 1: escaped, 2: settled in the heart
        for (; i < n; i++) {
            dz = 2 * complexMultiply(z, dz);
            z = float2(z.x * z.x - z.y * z.y, 2 * z.x * z.y) + c;
            r2 = dot(z, z);
            if (r2 > 1024) { state = 1; break; }
            if (distance_squared(z, fixed) < settle) { state = 2; break; }
            trap = min(trap, min(distance_squared(z, t0), min(distance_squared(z, t1), distance_squared(z, t2))));
        }
        float steps = float(i + 1);
        float glow = u.light.x;
        float hue = u.traps.w;

        // Outside: distance to the set in pixels, and the smooth escape time. An
        // orbit still going hasn't escaped to measure from; how hard it is still
        // stretching stands in, so only points right on the edge (or dust) light up.
        float lr = 0.5 * log(max(r2, 1.0001f));
        float stretch = rsqrt(max(dot(dz, dz), 1e-30f));
        float px = (state == 1 ? sqrt(r2) * lr * stretch : stretch) / pixel;
        float mu = steps - log2(max(lr, 1e-4f));
        // Inside: Koenigs' coordinate φ = (z − α) / λⁿ, as log-radius and turns. Its
        // second-order term, w + w²/(λ(1 − λ)), keeps the lace seamless where
        // neighbouring orbits settled a step apart.
        float2 w = z - fixed;
        float2 lambda = 2 * fixed;
        float2 bend = complexMultiply(lambda, float2(1, 0) - lambda);
        w += complexMultiply(float2(bend.x, -bend.y) / max(dot(bend, bend), 1e-6f), complexMultiply(w, w));
        float ring = 0.5 * log(max(dot(w, w), 1e-12f)) - steps * logRho;
        float ripples = contour(mu * 0.5, 1);

        // Only an orbit that has come close to α has a true φ to draw the lace and
        // light the centres with; one still settling slowly fades in as it nears.
        float settled = state == 2 ? 1.0 : smoothstep(0.15, 0.06, length(z - fixed));
        // An orbit still going that has stopped stretching is in the heart, just
        // settling slowly (near the cardioid's edge); one still stretching is on the edge.
        if (state == 0 && dot(dz, dz) < 1e6) state = 2;
        float3 light = 0;
        // Only the filaments themselves leave trails: halos and the heart would smear into mud.
        float3 ink = 0;
        // The vocals light the bulbs under their own wandering point most.
        float2 fromVoice = v - u.places.zw;
        float heart = u.light.y * (0.2 + 0.8 * exp(-dot(fromVoice, fromVoice) / 0.64));
        if (state != 2) {
            float3 tint = lightTint(u.colors, hue + around + 0.02 * mu);
            float width = u.view.w;
            float core = exp(-0.5 * px * px / (width * width));
            float halo = exp(-px / (4 + 6 * glow)) * 0.45 * glow + 0.07 * glow / (1 + 0.025 * px);
            float field = state == 1 ? ripples * 0.07 * exp(-0.008 * px) : 0.0;
            // Shattered, the outline is spread over a cloud of dust: each grain
            // gets less of its light, so a kick changes the shape, not the brightness.
            // Just past the edge the heart turns to a fine fur of dust that takes
            // ages to escape: it stays dim, so the outline still reads.
            float spread = 1 / (1 + 60 * max(0.0f, logRho)) / (1 + max(0.0f, mu - 30) / 12);
            ink = (tint * 1.2 + 0.45) * core * spread;
            light = ink + tint * halo * spread * spread + lightTint(u.colors, hue + around + 0.5) * field;
        } else {
            // The heart: light pools softly toward the centre of every bulb, where φ
            // is small, and thins out toward its rim. It's a smooth function of |φ|
            // alone, so it draws no lines.
            // The hue deepens away from each centre, held still right at it, where log |φ| runs off.
            float3 tint = lightTint(u.colors, hue + 0.45 + 0.04 * max(ring, -3.0f));
            // φ's scale shrinks as α weakens toward the cardioid's edge; the pools shrink with it.
            float reach = 0.002 + 20 * logRho * logRho;
            float q = exp(2 * ring) / (4 * reach);
            float pool = (0.6 * exp(-q) + 0.4 / (1 + q)) * settled;
            light = tint * (0.008 + 0.03 * heart + pool * (0.06 + 0.5 * heart));
        }
        // Hats glint out in the filaments, and give way where a kick is landing.
        float glintHere = (state != 2 ? 1.0 : 0.3) * (1 - 0.8 * kicked);
        light += mix(paletteLoop(u.colors, hue + 0.25), float3(1), 0.5) * exp(-trap * 900) * u.light.z * 0.9 * glintHere;
        // The drop's single wave runs out from the lens's edge point, lighting the filaments it passes.
        float wave = exp(-pow((length(v - u.places.xy) - u.wave.x) / 0.25, 2.0f)) * u.wave.y;
        float level = u.wave.z * (1 + 0.15 * u.light.w) * (1 + 3 * wave);
        light *= level;
        light += lightTint(u.colors, hue + around) * wave * 0.05;
        ink *= level;

        // Trails: last frame, faded and drifting outward a little, under this one.
        // They're read where this point of the plane was drawn last frame, so they
        // stay on the set as the view turns and zooms: only the set's own changes smear.
        float3 kept = 0;
        if (u.flags.x < 0.5) {
            constexpr sampler filtered(filter::linear, address::clamp_to_edge);
            float2 span = u.previous.zw;
            float2 was = complexMultiply(point - u.previous.xy, float2(span.x, -span.y)) / max(dot(span, span), 1e-12f);
            float2 st = float2(was.x / aspect * 0.5 + 0.5, 0.5 - was.y * 0.5); // textures run top-down
            st = 0.5 + (st - 0.5) * (1 - u.size.w);
            // Off the kept frame's edge (as the view zooms out) there's nothing to keep.
            bool inside = all(st >= 0.0) && all(st <= 1.0);
            kept = inside ? trails.sample(filtered, st).rgb * u.size.z : 0.0;
        }
        float3 total = max(ink, kept);
        // Trails are kept at full strength but shown softer than the live outline.
        float3 shown = max(light, kept * 0.45);

        float3 average = (u.colors[0].rgb + u.colors[1].rgb + u.colors[2].rgb + u.colors[3].rgb + u.colors[4].rgb) * 0.2;
        float3 color = float3(0.008, 0.009, 0.013) + average * 0.02 + shown;
        color = 1 - exp(-color * 1.2); // highlights roll off instead of clipping
        color = limitLuma(color, 0.38, 0.6);
        float alpha = 0.92;
        BloomOutput out;
        out.color = float4(color * alpha + dither(in.position.xy), alpha); // premultiplied, over the cover backdrop
        out.trails = float4(total, 1);
        return out;
    }
    """#
}
