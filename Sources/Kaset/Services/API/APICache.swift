import CryptoKit
import Foundation

/// Thread-safe cache for API responses with TTL and LRU eviction support.
/// Uses @MainActor since YTMusicClient is also @MainActor.
@MainActor
final class APICache {
    static let shared = APICache()

    struct WriteTicket {
        fileprivate let cacheGeneration: Int
        fileprivate let scopedInvalidationOrder: UInt64
        fileprivate let requestOrder: UInt64
    }

    struct WriteReservation {
        fileprivate let key: String
        fileprivate let ticket: WriteTicket
    }

    struct CacheEntry {
        let data: [String: Any]
        let timestamp: Date
        let ttl: TimeInterval
        /// Size of the response as received (raw JSON bytes). The parsed Foundation
        /// object graph is several times larger, so this is a proportional proxy.
        let cost: Int
        var lastAccessed: Date

        var isExpired: Bool {
            Date().timeIntervalSince(self.timestamp) > self.ttl
        }

        init(data: [String: Any], timestamp: Date, ttl: TimeInterval, cost: Int = 0) {
            self.data = data
            self.timestamp = timestamp
            self.ttl = ttl
            self.cost = max(0, cost)
            self.lastAccessed = timestamp
        }
    }

    /// TTL values for different endpoint types.
    enum TTL {
        static let home: TimeInterval = 5 * 60 // 5 minutes
        static let playlist: TimeInterval = 30 * 60 // 30 minutes
        static let artist: TimeInterval = 60 * 60 // 1 hour
        static let search: TimeInterval = 2 * 60 // 2 minutes
        static let library: TimeInterval = 5 * 60 // 5 minutes
        static let lyrics: TimeInterval = 24 * 60 * 60 // 24 hours
        static let songMetadata: TimeInterval = 30 * 60 // 30 minutes
    }

    /// Maximum number of cached entries before LRU eviction kicks in.
    private static let maxEntries = 50

    /// Upper bound on the summed raw size of cached responses. Parsed JSON costs
    /// roughly 3–6× its wire size in Foundation objects, so 8 MB of responses is
    /// ~25–50 MB resident. Before this cap only the 50-entry count applied, and
    /// 50 large browse/next responses (300 KB–1 MB each) could pin 100+ MB.
    static let defaultMaxTotalCost = 8 * 1024 * 1024

    private let maxTotalCost: Int

    /// Pre-allocated dictionary with initial capacity to reduce rehashing.
    private var cache: [String: CacheEntry]

    /// Cacheable request order is allocated before any reentrant authentication
    /// work, then claimed after the scoped cache key is known. This prevents an
    /// older request from becoming the newest writer merely because its header
    /// construction resumed later.
    private var nextWriteOrder: UInt64 = 0
    private var nextScopedInvalidationOrder: UInt64 = 0
    private var activeWriteOrders: Set<UInt64> = []
    private var latestWriteOrders: [String: UInt64] = [:]
    /// Most recent invalidation order for each cache-key prefix.
    private var latestScopedInvalidationOrders: [String: UInt64] = [:]

    /// Timestamp of last eviction to avoid running on every access.
    private var lastEvictionTime: Date = .distantPast

    /// Minimum interval between automatic evictions (30 seconds).
    private static let evictionInterval: TimeInterval = 30

    init(maxTotalCost: Int = APICache.defaultMaxTotalCost) {
        // Pre-allocate capacity to avoid rehashing during normal operation
        self.cache = Dictionary(minimumCapacity: Self.maxEntries)
        self.maxTotalCost = max(1, maxTotalCost)
    }

    /// Summed `cost` of all cached entries (≤ 50 entries, so summing is cheap).
    var totalCost: Int {
        self.cache.values.reduce(0) { $0 + $1.cost }
    }

    /// Gets cached data if available and not expired.
    func get(key: String) -> [String: Any]? {
        guard var entry = cache[key] else { return nil }

        if entry.isExpired {
            self.cache.removeValue(forKey: key)
            return nil
        }

        // Update last accessed time for LRU tracking
        entry.lastAccessed = Date()
        self.cache[key] = entry
        return entry.data
    }

    /// Stores data in the cache with the specified TTL.
    /// Evicts least recently used entries if cache is at capacity.
    func set(key: String, data: [String: Any], ttl: TimeInterval, cost: Int = 0) {
        let now = Date()

        // Evict expired entries periodically (not on every set)
        if now.timeIntervalSince(self.lastEvictionTime) > Self.evictionInterval {
            self.evictExpiredEntries()
            self.lastEvictionTime = now
        }

        // A replaced entry must not count against the budget for its successor.
        self.cache.removeValue(forKey: key)

        // Evict LRU entries while at capacity by count or by bytes. The newest
        // response is always kept, even if it alone exceeds the byte budget.
        while !self.cache.isEmpty,
              self.cache.count >= Self.maxEntries || self.totalCost + max(0, cost) > self.maxTotalCost
        {
            self.evictLeastRecentlyUsed()
        }

        self.cache[key] = CacheEntry(data: data, timestamp: now, ttl: ttl, cost: cost)
    }

    /// Drops expired entries now. Called when the main window hides, so stale
    /// responses do not stay resident until the next write.
    func purgeExpired() {
        self.evictExpiredEntries()
        self.lastEvictionTime = Date()
    }

    /// Key under which raw `Data` payloads are boxed inside a `CacheEntry`, so
    /// raw-bytes caching reuses the same TTL / LRU / eviction machinery as the
    /// deserialized-dict cache instead of a parallel store.
    private static let rawDataBoxKey = "__APICacheRawData__"

    /// Gets cached raw bytes if available and not expired.
    func getData(key: String) -> Data? {
        self.get(key: key)?[Self.rawDataBoxKey] as? Data
    }

    /// Stores raw bytes in the cache with the specified TTL.
    func setData(key: String, data: Data, ttl: TimeInterval) {
        self.set(key: key, data: [Self.rawDataBoxKey: data], ttl: ttl, cost: data.count)
    }

    /// Allocates logical request order before the caller's first `await`.
    func prepareWrite(cacheGeneration: Int) -> WriteTicket? {
        guard cacheGeneration == self.generation else { return nil }
        self.nextWriteOrder &+= 1
        let ticket = WriteTicket(
            cacheGeneration: cacheGeneration,
            scopedInvalidationOrder: self.nextScopedInvalidationOrder,
            requestOrder: self.nextWriteOrder
        )
        self.activeWriteOrders.insert(ticket.requestOrder)
        return ticket
    }

    /// Claims the resolved cache key for a network response. A newer ticket for
    /// the same key supersedes an older one regardless of await completion order.
    func beginWrite(for key: String, ticket: WriteTicket) -> WriteReservation? {
        guard ticket.cacheGeneration == self.generation,
              self.activeWriteOrders.contains(ticket.requestOrder),
              !self.wasInvalidated(ticket, for: key),
              ticket.requestOrder > (self.latestWriteOrders[key] ?? 0)
        else {
            return nil
        }
        self.latestWriteOrders[key] = ticket.requestOrder
        return WriteReservation(key: key, ticket: ticket)
    }

    /// Stores a dictionary response only while its write reservation is still
    /// current and no relevant cache invalidation occurred during the request.
    func setIfCurrent(
        key: String,
        data: [String: Any],
        ttl: TimeInterval,
        cost: Int = 0,
        reservation: WriteReservation
    ) {
        guard self.isCurrent(reservation, for: key) else { return }
        self.set(key: key, data: data, ttl: ttl, cost: cost)
    }

    /// Raw-data counterpart to `setIfCurrent`, used by YouTube's large Home
    /// response so it follows the same newest-request-wins rule.
    func setDataIfCurrent(
        key: String,
        data: Data,
        ttl: TimeInterval,
        reservation: WriteReservation
    ) {
        guard self.isCurrent(reservation, for: key) else { return }
        self.setData(key: key, data: data, ttl: ttl)
    }

    /// Releases a completed, failed, or cache-hit request ticket. Key ordering
    /// stays recorded while any older ticket could still resume and claim it.
    func finishWrite(_ ticket: WriteTicket) {
        guard ticket.cacheGeneration == self.generation else {
            return
        }
        self.activeWriteOrders.remove(ticket.requestOrder)
        self.pruneWriteOrderState()
    }

    private static let logger = DiagnosticsLogger.api

    /// Generates a stable, deterministic cache key from endpoint, request body, and brand ID.
    /// Uses SHA256 hash of sorted JSON to ensure consistency.
    /// Including brandId ensures cache isolation between accounts.
    static func stableCacheKey(endpoint: String, body: [String: Any], brandId: String = "") -> String {
        // Use JSONSerialization with .sortedKeys for deterministic output
        // This is more efficient than custom recursive string building
        let jsonData: Data
        do {
            // .sortedKeys available since macOS 10.13, we target macOS 26+
            jsonData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        } catch {
            // Log the error and use endpoint-only key to avoid collisions
            Self.logger.error("APICache: Failed to serialize body for cache key: \(error.localizedDescription)")
            // Return endpoint-only key with error marker to avoid collisions
            return "\(endpoint):serialization_error_\(body.count)"
        }

        // Include brand ID in hash to isolate cache between accounts
        var hashData = jsonData
        if !brandId.isEmpty {
            // Use NUL byte separator to avoid ambiguity between JSON and brandId bytes
            hashData.append(0)
            hashData.append(Data(brandId.utf8))
        }

        let hash = SHA256.hash(data: hashData)
        let hashString = hash.prefix(16).compactMap { String(format: "%02x", $0) }.joined()
        return "\(endpoint):\(hashString)"
    }

    /// Monotonic counter bumped on every full invalidation (account switch,
    /// sign-out, session expiry). Callers that fetch across an `await` can
    /// capture it before the fetch and refuse to write a now-stale response —
    /// e.g. bytes fetched for a user who signed out mid-flight, whose cache
    /// scope key may be unchanged (the account-unknown `pending` scope).
    private(set) var generation = 0

    /// Invalidates all cached entries.
    func invalidateAll() {
        self.cache.removeAll()
        self.generation &+= 1
        self.invalidateAllPendingWrites()
    }

    /// Invalidates entries matching the given prefix.
    func invalidate(matching prefix: String) {
        self.cache = self.cache.filter { !$0.key.hasPrefix(prefix) }
        self.invalidatePendingWrites(matching: [prefix])
    }

    /// Invalidates all caches affected by mutation operations (like, library, feedback).
    /// More efficient than multiple invalidate(matching:) calls as it iterates only once.
    func invalidateMutationCaches() {
        let mutationPrefixes = [
            "browse:",
            "next:",
            "like:",
            "playlist/get_add_to_playlist:",
        ]
        self.cache = self.cache.filter { entry in
            !mutationPrefixes.contains { entry.key.hasPrefix($0) }
        }
        self.invalidatePendingWrites(matching: mutationPrefixes)
    }

    /// Returns current cache statistics for debugging.
    var stats: (count: Int, expired: Int) {
        let expired = self.cache.values.filter(\.isExpired).count
        return (self.cache.count, expired)
    }

    // MARK: - Private Helpers

    /// Evicts all expired entries from the cache.
    private func evictExpiredEntries() {
        self.cache = self.cache.filter { !$0.value.isExpired }
    }

    /// Evicts the least recently used entry from the cache.
    private func evictLeastRecentlyUsed() {
        guard let lruKey = cache.min(by: { $0.value.lastAccessed < $1.value.lastAccessed })?.key else {
            return
        }
        self.cache.removeValue(forKey: lruKey)
    }

    private func isCurrent(_ reservation: WriteReservation, for key: String) -> Bool {
        reservation.key == key
            && reservation.ticket.cacheGeneration == self.generation
            && self.activeWriteOrders.contains(reservation.ticket.requestOrder)
            && !self.wasInvalidated(reservation.ticket, for: key)
            && self.latestWriteOrders[key] == reservation.ticket.requestOrder
    }

    private func invalidateAllPendingWrites() {
        self.activeWriteOrders.removeAll()
        self.latestWriteOrders.removeAll()
        self.latestScopedInvalidationOrders.removeAll()
    }

    private func invalidatePendingWrites(matching prefixes: [String]) {
        guard !prefixes.isEmpty else { return }

        self.nextScopedInvalidationOrder &+= 1
        let invalidationOrder = self.nextScopedInvalidationOrder
        for prefix in prefixes {
            self.latestScopedInvalidationOrders[prefix] = invalidationOrder
        }
        self.latestWriteOrders = self.latestWriteOrders.filter { entry in
            !prefixes.contains { entry.key.hasPrefix($0) }
        }
    }

    private func wasInvalidated(_ ticket: WriteTicket, for key: String) -> Bool {
        self.latestScopedInvalidationOrders.contains { entry in
            entry.value > ticket.scopedInvalidationOrder && key.hasPrefix(entry.key)
        }
    }

    private func pruneWriteOrderState() {
        guard let oldestActiveOrder = self.activeWriteOrders.min() else {
            self.latestWriteOrders.removeAll()
            return
        }
        self.latestWriteOrders = self.latestWriteOrders.filter { $0.value >= oldestActiveOrder }
    }
}
