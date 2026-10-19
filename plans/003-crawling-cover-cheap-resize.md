# 003 — Resize the crawling cover without rebuilding its motion every frame

- **Status**: DONE
- **Commit**: e102e24
- **Severity**: HIGH
- **Category**: Performance
- **Estimated scope**: 1 file (`Sources/Floe/Views/CrawlingCover.swift`), ~40 lines; maybe `Tests/LayerTests.swift`

## Problem

The Now Playing cover changes size on every frame of two frequent animations: the hero flight between the mini player and Now Playing, and the cover shrinking/growing when the lyrics column is toggled (⇧⌘L, `NowPlayingView.swift:24`, cover 420 ↔ 330 pt). On each new size, `layout()` rebuilds three 353-point blob paths and replaces four Core Animation animations, and the shape layers re-rasterize:

```swift
// Sources/Floe/Views/CrawlingCover.swift:84-97 — current
override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    content.frame = bounds
    imageLayer.frame = bounds
    for shape in [maskLayer, rimLayer] {
        shape.frame = bounds
    }
    if bounds.size != pathSize, bounds.width > 0 {
        pathSize = bounds.size
        installMotion()
    }
    CATransaction.commit()
}
```

That is main-thread work in every frame of the transition — a likely cause of the "swapping lyrics and cover" stutter.

## Target

While the size is changing, scale the existing paths with a transform (cheap, render-server only). Rebuild the paths at the new size once the size has been still for 0.15 s. Steady-state cost stays exactly as today (paths at true size, no upscaled raster).

- Two host layers: `maskHost` (becomes `imageLayer.mask`, contains `maskLayer`) and `rimHost` (added to `content` in `rimLayer`'s place, contains `rimLayer`).
- `maskLayer` / `rimLayer`: `bounds = CGRect(origin: .zero, size: pathSize)`, `position = CGPoint(x: bounds.midX, y: bounds.midY)` of the host. Their own `transform` stays free for the crawl animation (`transform.rotation.z`), which must keep rotating about their centre.
- Hosts: `frame = bounds`; `sublayerTransform = CATransform3DMakeScale(bounds.width / pathSize.width, bounds.height / pathSize.height, 1)` while resized, identity after a rebuild. (`sublayerTransform` applies about the host's anchor point, the centre, so a centred child scales in place.)
- `rimLayer.lineWidth = rimWidth / scaleX` while scaled, so the rim keeps its width during the flight. Store `rimWidth` from `update(...)` in a property.
- First layout (`pathSize == .zero`): build immediately, as today.
- Settle: cancel and reschedule a rebuild 0.15 s after the last size change (a `DispatchWorkItem` on the main queue, or a `Task { @MainActor in try await Task.sleep(for: .seconds(0.15)) … }` stored and cancelled). The rebuild sets `pathSize = bounds.size`, calls `installMotion()` (unchanged — it already keeps the crawl/breath phase via `epoch`), resets the hosts' `sublayerTransform` to identity and the child bounds/position, and restores `rimLayer.lineWidth = rimWidth`, all inside `CATransaction.setDisableActions(true)`.
- `crawlAngle` keeps reading `maskLayer.presentation()`'s `transform.rotation.z` (the self-test uses it).
- Set `contentsScale` on the two new host layers in `viewDidChangeBackingProperties()` too.

## Repo conventions to follow

- All layer mutations are wrapped in `CATransaction.begin(); setDisableActions(true); … commit()` (see `update(...)` at `:63-81`).
- Comment the "why" briefly above the settle logic, e.g. "Scaling mid-flight is free on the render server; rebuilding the paths every frame of the hero flight was main-thread work."
- Swift 6: the view is main-actor; a `Task { @MainActor in … }` or main-queue work item is fine. No closures handed to other threads.

## Steps

1. Add `maskHost`, `rimHost` (`CALayer`), `rimWidth: CGFloat = 0`, and a settle handle property. In `init`, build the hierarchy: `content.addSublayer(imageLayer)`, `content.addSublayer(rimHost)`, `rimHost.addSublayer(rimLayer)`, `maskHost.addSublayer(maskLayer)`, `imageLayer.mask = maskHost`.
2. In `update(...)`, store `self.rimWidth = rimWidth` and set `rimLayer.lineWidth` to `rimWidth` divided by the current host scale (1 when not scaled).
3. Rewrite `layout()` per Target: frames for `content`, `imageLayer`, hosts; on first size build immediately; on later size changes set the scale transform + line width, then (re)schedule the settle rebuild.
4. Add the private `rebuild()` used by both paths.
5. Run `scripts/test-layers.sh`. If the existing "resize" check expects paths at the new size synchronously, add an internal `func settleNow()` that runs the pending rebuild immediately, and call it in the test right after the resize — do not weaken the assertion.

## Boundaries

- Only `CrawlingCover.swift` (and `Tests/LayerTests.swift` if step 5 needs `settleNow()`).
- Do NOT change `BlobShape`, timings (`turn`, `breath`), the image crossfade, or `setRunning`.
- On drift, STOP and report.

## Verification

- **Mechanical**: `swift build -c release` and `scripts/test-layers.sh` (PASS with all checks).
- **Feel check** (owner): with music playing, toggle Now Playing's lyrics column repeatedly and click the mini cover to fly to Now Playing: the cover resizes smoothly, the petals never stop or jump in phase, and the rim doesn't thicken during the flight. In Activity Monitor, CPU during a toggle should spike less than before.
- **Done when**: `installMotion()` runs once per settled size, never per frame of a resize.
