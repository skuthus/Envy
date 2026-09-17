import SwiftUI

/// Shared geometry tokens, so the app's corners and spacing read on one scale
/// rather than ad-hoc per view.
///
/// Radii are meant to be used with SwiftUI's `.continuous` (squircle) curvature
/// to match macOS, and nested concentrically where it matters (an inner radius
/// ≈ outer radius − padding).
enum Radius {
    /// Chips, list-row selection, small inline fields.
    static let small: CGFloat = 6
    /// Cards, colour swatches, grouped controls.
    static let medium: CGFloat = 10
    /// Prominent panels and callouts.
    static let large: CGFloat = 14
}

/// A 4pt spacing scale. Prefer these over bare numbers for layout gaps so the
/// app keeps a consistent rhythm.
enum Spacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
}
