import Darwin

/// The process's physical footprint (what Activity Monitor calls Memory), in bytes.
enum MemoryFootprint {
    static func current() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// Returns freed-but-held allocator pages to the system, so the footprint
    /// drops back after a conversion or a wheel (idle budget, PLAN.md §5).
    static func relieve() {
        malloc_zone_pressure_relief(nil, 0)
    }

    static var megabytes: String { String(format: "%.1f MB", Double(current()) / 1_048_576) }
}
