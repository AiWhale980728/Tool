import CoreGraphics
import Testing
@testable import RelayCore

@Suite("Hardware notch geometry")
struct NotchDisplayGeometryTests {
    @Test
    func derivesNotchFromBothMenuBarAreas() throws {
        let rect = try #require(NotchDisplayGeometry.notchRect(
            screenFrame: CGRect(x: 0, y: 0, width: 1_440, height: 932),
            leftMenuBarArea: CGRect(x: 0, y: 904, width: 642, height: 28),
            rightMenuBarArea: CGRect(x: 798, y: 904, width: 642, height: 28)
        ))

        #expect(rect == CGRect(x: 642, y: 904, width: 156, height: 28))
    }

    @Test
    func rejectsScreensWithoutTwoValidAreas() {
        #expect(NotchDisplayGeometry.notchRect(
            screenFrame: CGRect(x: 0, y: 0, width: 1_440, height: 932),
            leftMenuBarArea: nil,
            rightMenuBarArea: CGRect(x: 798, y: 904, width: 642, height: 28)
        ) == nil)
        #expect(NotchDisplayGeometry.notchRect(
            screenFrame: CGRect(x: 0, y: 0, width: 1_440, height: 932),
            leftMenuBarArea: CGRect(x: 0, y: 904, width: 800, height: 28),
            rightMenuBarArea: CGRect(x: 700, y: 904, width: 740, height: 28)
        ) == nil)
    }
}
