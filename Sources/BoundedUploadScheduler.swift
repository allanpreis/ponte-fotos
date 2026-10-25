import Foundation

/// Schedules whole media units. All decisions and callbacks run on the UI actor;
/// resource work may suspend without allowing another unit to own the same hash.
enum PFBoundedUploadScheduler {
    @MainActor static func run<Item>(
        items: [Item],
        limit: Int = 2,
        resourceKeys: @MainActor (Item) -> Set<String>,
        shouldPause: @MainActor () -> Bool,
        operation: @escaping @MainActor (Item) async -> Void,
        onComplete: @MainActor (Item) -> Void = { _ in }
    ) async {
        let concurrency = max(1, min(limit, 4))
        let keys = items.map { resourceKeys($0) }
        var pending = Array(items.indices)
        var active: [Int: Set<String>] = [:]
        var occupied: Set<String> = []

        await withTaskGroup(of: Int.self) { group in
            while !pending.isEmpty || !active.isEmpty {
                while active.count < concurrency && !shouldPause() && !Task.isCancelled {
                    // Skip a conflicting unit rather than blocking independent work behind it.
                    guard let position = pending.firstIndex(where: { keys[$0].isDisjoint(with: occupied) }) else { break }
                    let index = pending.remove(at: position)
                    active[index] = keys[index]
                    occupied.formUnion(keys[index])
                    group.addTask { @MainActor in
                        await operation(items[index])
                        return index
                    }
                }

                guard !active.isEmpty, let finished = await group.next() else { break }
                if let released = active.removeValue(forKey: finished) { occupied.subtract(released) }
                onComplete(items[finished])
            }
            // Leaving the group awaits every started operation. A pause stops new units;
            // it never cancels a Live Photo between its paired video and image.
        }
    }
}
