import Foundation
import Testing
@testable import RelayCore

@Suite("Balance and system workload signals")
struct WorkloadSignalsTests {
    @Test
    func testBalanceFractionAndStaleness() throws {
        let refreshed = Date(timeIntervalSince1970: 1_000)
        let balance = try #require(ProviderBalanceSnapshot(
            providerID: "provider",
            displayName: "Provider",
            kind: .subscriptionQuota,
            state: .normal,
            remaining: 25,
            limit: 100,
            unit: "requests",
            refreshedAt: refreshed,
            dataSource: .officialAPI
        ))

        #expect(balance.fractionRemaining == 0.25)
        #expect(balance.effectiveState(now: refreshed.addingTimeInterval(14 * 60)) == .normal)
        #expect(balance.effectiveState(now: refreshed.addingTimeInterval(16 * 60)) == .stale)
    }

    @Test
    func testUnavailableAndSignInStatesDoNotBecomeStale() throws {
        let old = Date(timeIntervalSince1970: 1_000)
        let unavailable = try #require(ProviderBalanceSnapshot(
            providerID: "unknown",
            displayName: "Unknown",
            kind: .apiCredit,
            state: .unavailable,
            refreshedAt: old,
            dataSource: .documentedLocalInterface
        ))
        let signIn = try #require(ProviderBalanceSnapshot(
            providerID: "sign-in",
            displayName: "Sign in",
            kind: .subscriptionQuota,
            state: .signInRequired,
            refreshedAt: old,
            dataSource: .officialAPI
        ))
        let muchLater = old.addingTimeInterval(24 * 60 * 60)

        #expect(unavailable.effectiveState(now: muchLater) == .unavailable)
        #expect(signIn.effectiveState(now: muchLater) == .signInRequired)
    }

    @Test
    func testInvalidBalanceNumbersAreRejected() {
        #expect(ProviderBalanceSnapshot(
            providerID: "provider",
            displayName: "Provider",
            kind: .apiCredit,
            state: .normal,
            remaining: -1,
            dataSource: .manual
        ) == nil)
        #expect(ProviderBalanceSnapshot(
            providerID: "provider",
            displayName: "Provider",
            kind: .apiCredit,
            state: .normal,
            limit: 0,
            dataSource: .manual
        ) == nil)
    }

    @Test
    func testSystemMetricsNeverExposeInvalidFractionsOrCounts() {
        let snapshot = SystemWorkloadSnapshot(
            thermalPressure: .warm,
            cpuUtilization: 1.5,
            memoryPressure: 0.5,
            batteryLevel: -0.1,
            localActiveTaskCount: -1
        )

        #expect(snapshot.cpuUtilization == nil)
        #expect(snapshot.memoryPressure == 0.5)
        #expect(snapshot.batteryLevel == nil)
        #expect(snapshot.localActiveTaskCount == nil)
    }

    @Test
    func testOfficialMacThermalStatesMapWithoutInventingCelsius() {
        #expect(MacSystemWorkloadReader.thermalPressure(from: .nominal) == .cool)
        #expect(MacSystemWorkloadReader.thermalPressure(from: .fair) == .warm)
        #expect(MacSystemWorkloadReader.thermalPressure(from: .serious) == .hot)
        #expect(MacSystemWorkloadReader.thermalPressure(from: .critical) == .coolingNeeded)
    }
}
