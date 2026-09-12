import Foundation

struct ObserverRegistry<Callback> {
    private var observers: [UUID: (tokenId: String, callback: Callback)] = [:]
    private var metadata: [UUID: Date] = [:]

    @discardableResult
    mutating func add(tokenId: String, callback: Callback) -> UUID {
        let id = UUID()
        observers[id] = (tokenId: tokenId, callback: callback)
        metadata[id] = Date()
        return id
    }

    mutating func remove(id: UUID) {
        observers.removeValue(forKey: id)
        metadata.removeValue(forKey: id)
    }

    func forToken(_ tokenId: String) -> [(id: UUID, callback: Callback)] {
        observers.compactMap { key, value in
            value.tokenId == tokenId ? (id: key, callback: value.callback) : nil
        }
    }

    mutating func purgeStale(olderThan cutoff: Date) -> Int {
        let stale = metadata.filter { $0.value < cutoff }.map(\.key)
        for id in stale { remove(id: id) }
        return stale.count
    }

    var count: Int { observers.count }
}
