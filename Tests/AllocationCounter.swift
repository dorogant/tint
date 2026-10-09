import Darwin

/// Counts heap allocations made on the main thread, for the per-frame cost
/// reports. It swaps the default malloc zone's entry points for counting ones
/// (test processes only), so it sees Swift, Objective-C and Core Foundation
/// allocations alike. Other threads aren't counted: Metal and Core Animation
/// allocate on their own, and the frame paths measured here run on main.
enum AllocationCounter {
    private typealias Malloc = @convention(c) (UnsafeMutablePointer<malloc_zone_t>?, Int) -> UnsafeMutableRawPointer?
    private typealias Calloc = @convention(c) (UnsafeMutablePointer<malloc_zone_t>?, Int, Int) -> UnsafeMutableRawPointer?
    private typealias Realloc = @convention(c) (UnsafeMutablePointer<malloc_zone_t>?, UnsafeMutableRawPointer?, Int) -> UnsafeMutableRawPointer?
    private typealias TypedMalloc = @convention(c) (UnsafeMutablePointer<malloc_zone_t>?, Int, malloc_type_id_t) -> UnsafeMutableRawPointer?
    private typealias TypedCalloc = @convention(c) (UnsafeMutablePointer<malloc_zone_t>?, Int, Int, malloc_type_id_t) -> UnsafeMutableRawPointer?
    private typealias TypedRealloc = @convention(c) (UnsafeMutablePointer<malloc_zone_t>?, UnsafeMutableRawPointer?, Int, malloc_type_id_t) -> UnsafeMutableRawPointer?

    // Written once in `install` before any counting, then only read; `count`
    // is touched by the main thread alone.
    nonisolated(unsafe) private static var count = 0
    nonisolated(unsafe) private static var malloc: Malloc?
    nonisolated(unsafe) private static var calloc: Calloc?
    nonisolated(unsafe) private static var realloc: Realloc?
    nonisolated(unsafe) private static var typedMalloc: TypedMalloc?
    nonisolated(unsafe) private static var typedCalloc: TypedCalloc?
    nonisolated(unsafe) private static var typedRealloc: TypedRealloc?
    nonisolated(unsafe) private static var installed = false

    private static func tally() { if pthread_main_np() == 1 { count += 1 } }

    /// Allocations made on the main thread while `body` runs.
    static func allocations(_ body: () -> Void) -> Int {
        install()
        let before = count
        body()
        return count - before
    }

    private static func install() {
        guard !installed else { return }
        installed = true
        var addresses: UnsafeMutablePointer<vm_address_t>?
        var zones: UInt32 = 0
        // malloc_default_zone() returns a forwarding stub; the real default zone comes first here.
        guard malloc_get_all_zones(mach_task_self_, nil, &addresses, &zones) == KERN_SUCCESS, zones > 0,
              let zone = UnsafeMutablePointer<malloc_zone_t>(bitPattern: UInt(addresses![0])) else { return }
        let page = UInt(getpagesize())
        let start = UInt(bitPattern: zone) & ~(page - 1)
        guard vm_protect(mach_task_self_, vm_address_t(start), vm_size_t(page * 2), 0, VM_PROT_READ | VM_PROT_WRITE) == KERN_SUCCESS
        else { return }
        malloc = zone.pointee.malloc
        calloc = zone.pointee.calloc
        realloc = zone.pointee.realloc
        zone.pointee.malloc = { zone, size in AllocationCounter.tally(); return AllocationCounter.malloc!(zone, size) }
        zone.pointee.calloc = { zone, n, size in AllocationCounter.tally(); return AllocationCounter.calloc!(zone, n, size) }
        zone.pointee.realloc = { zone, pointer, size in AllocationCounter.tally(); return AllocationCounter.realloc!(zone, pointer, size) }
        // Swift and the system frameworks allocate through the typed entry points.
        guard zone.pointee.version >= 16 else { return }
        typedMalloc = zone.pointee.malloc_type_malloc
        typedCalloc = zone.pointee.malloc_type_calloc
        typedRealloc = zone.pointee.malloc_type_realloc
        zone.pointee.malloc_type_malloc = { zone, size, type in AllocationCounter.tally(); return AllocationCounter.typedMalloc!(zone, size, type) }
        zone.pointee.malloc_type_calloc = { zone, n, size, type in AllocationCounter.tally(); return AllocationCounter.typedCalloc!(zone, n, size, type) }
        zone.pointee.malloc_type_realloc = { zone, pointer, size, type in
            AllocationCounter.tally(); return AllocationCounter.typedRealloc!(zone, pointer, size, type)
        }
    }
}
