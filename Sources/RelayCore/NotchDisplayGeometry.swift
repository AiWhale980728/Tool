import CoreGraphics

/// Hardware-notch geometry derived from the two usable menu-bar areas.
/// This remains deterministic and AppKit-free so multi-display behavior can
/// be verified without creating real screens in tests.
public enum NotchDisplayGeometry {
    public static func notchRect(
        screenFrame: CGRect,
        leftMenuBarArea: CGRect?,
        rightMenuBarArea: CGRect?
    ) -> CGRect? {
        guard let leftMenuBarArea, let rightMenuBarArea else { return nil }
        let minimumX = leftMenuBarArea.maxX
        let maximumX = rightMenuBarArea.minX
        let minimumY = max(leftMenuBarArea.minY, rightMenuBarArea.minY)
        let maximumY = min(leftMenuBarArea.maxY, rightMenuBarArea.maxY)
        guard maximumX > minimumX,
              maximumY > minimumY,
              screenFrame.intersects(CGRect(
                x: minimumX,
                y: minimumY,
                width: maximumX - minimumX,
                height: maximumY - minimumY
              )) else { return nil }

        return CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        )
    }
}
