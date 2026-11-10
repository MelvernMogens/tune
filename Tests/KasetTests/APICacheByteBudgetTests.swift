import Foundation
import Testing
@testable import Kaset

// MARK: - APICacheByteBudgetTests

@Suite(.tags(.service))
@MainActor
struct APICacheByteBudgetTests {
    @Test("Byte budget evicts the least recently used response")
    func byteBudgetEvictsLeastRecentlyUsed() async throws {
        let cache = APICache(maxTotalCost: 1000)
        cache.set(key: "a", data: ["v": 1], ttl: 60, cost: 400)
        try await Task.sleep(for: .milliseconds(5))
        cache.set(key: "b", data: ["v": 2], ttl: 60, cost: 400)
        try await Task.sleep(for: .milliseconds(5))
        _ = cache.get(key: "a") // a is now more recent than b
        try await Task.sleep(for: .milliseconds(5))
        cache.set(key: "c", data: ["v": 3], ttl: 60, cost: 400)

        #expect(cache.get(key: "a") != nil)
        #expect(cache.get(key: "b") == nil)
        #expect(cache.get(key: "c") != nil)
        #expect(cache.totalCost == 800)
    }

    @Test("A response larger than the budget is still kept, alone")
    func oversizedResponseIsKeptAlone() {
        let cache = APICache(maxTotalCost: 1000)
        cache.set(key: "small", data: ["v": 1], ttl: 60, cost: 100)
        cache.set(key: "huge", data: ["v": 2], ttl: 60, cost: 5000)

        #expect(cache.get(key: "huge") != nil)
        #expect(cache.get(key: "small") == nil)
        #expect(cache.totalCost == 5000)
    }

    @Test("Replacing a key does not double-charge it")
    func replacingKeyDoesNotDoubleCharge() {
        let cache = APICache(maxTotalCost: 1000)
        cache.set(key: "other", data: ["v": 0], ttl: 60, cost: 300)
        cache.set(key: "a", data: ["v": 1], ttl: 60, cost: 600)
        cache.set(key: "a", data: ["v": 2], ttl: 60, cost: 600)

        #expect(cache.get(key: "other") != nil)
        #expect(cache.get(key: "a")?["v"] as? Int == 2)
        #expect(cache.totalCost == 900)
    }

    @Test("Raw data entries are charged their byte count")
    func rawDataIsChargedByteCount() {
        let cache = APICache(maxTotalCost: 1000)
        cache.setData(key: "raw", data: Data(count: 700), ttl: 60)
        #expect(cache.totalCost == 700)
    }

    @Test("purgeExpired drops expired entries immediately")
    func purgeExpiredDropsExpiredEntries() async throws {
        let cache = APICache(maxTotalCost: 1000)
        cache.set(key: "short", data: ["v": 1], ttl: 0.01, cost: 10)
        cache.set(key: "long", data: ["v": 2], ttl: 60, cost: 10)
        try await Task.sleep(for: .milliseconds(30))

        cache.purgeExpired()

        #expect(cache.stats.count == 1)
        #expect(cache.get(key: "long") != nil)
    }
}
