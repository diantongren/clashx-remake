import Testing
@testable import ConfigKit

@Suite("PortAllocator")
struct PortAllocatorTests {
    @Test func prefersRequestedPort() {
        var allocator = PortAllocator.simulated(busy: [])
        #expect(allocator.claim(preferring: 7890) == 7890)
    }

    @Test func skipsBusyAndAlreadyClaimed() {
        var allocator = PortAllocator.simulated(busy: [7891])
        #expect(allocator.claim(preferring: 7890) == 7890)
        #expect(allocator.claim(preferring: 7890) == 7892)
    }

    @Test func realProbeFindsSomething() {
        var allocator = PortAllocator()
        let port = allocator.claim(preferring: 47890)
        #expect((1024..<65535).contains(port))
    }
}
