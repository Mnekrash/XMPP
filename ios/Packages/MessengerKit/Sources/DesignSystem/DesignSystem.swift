import SwiftUI

// DesignSystem: the app's own visual identity (no third-party branding). System fonts with Dynamic Type,
// system background colours (light/dark), one accent colour.

public enum Brand {
    /// Working product name; the final name is the owner's decision (one place to change).
    public static let name = "Messenger"
    public static let accent = Color(red: 0.16, green: 0.47, blue: 0.96)
    public static let accentDeep = Color(red: 0.09, green: 0.33, blue: 0.82)
    public static let gradient = LinearGradient(colors: [Color(red: 0.25, green: 0.60, blue: 1.0), accentDeep],
                                                startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// App logo: a rounded speech bubble with a small shield (private messaging). Drawn in code, scales cleanly.
public struct AppLogo: View {
    private let size: CGFloat

    public init(size: CGFloat = 96) {
        self.size = size
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Brand.gradient)
            BubbleShape()
                .fill(.white)
                .frame(width: size * 0.62, height: size * 0.52)
                .offset(y: -size * 0.02)
            Image(systemName: "lock.fill")
                .font(.system(size: size * 0.2, weight: .bold))
                .foregroundStyle(Brand.accentDeep)
                .offset(y: -size * 0.05)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Speech bubble with a tail at the lower left.
public struct BubbleShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.82)
        var path = Path(roundedRect: body, cornerRadius: body.height * 0.42, style: .continuous)
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.18, y: body.maxY - 2))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.10, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: body.maxY - 2))
        path.closeSubpath()
        return path
    }
}

/// Full-width primary button with a loading state.
public struct PrimaryButtonStyle: ButtonStyle {
    private let isLoading: Bool

    public init(isLoading: Bool = false) {
        self.isLoading = isLoading
    }

    public func makeBody(configuration: Configuration) -> some View {
        ZStack {
            configuration.label.opacity(isLoading ? 0 : 1)
            if isLoading { ProgressView().tint(.white) }
        }
        .font(.headline)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 50)
        .background(Brand.accent.opacity(configuration.isPressed ? 0.8 : 1),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Rounded input field container used on the login screens.
public struct FieldBackground: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            .background(Color(uiColorCompatible: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

extension Color {
    /// System colour that adapts to light/dark mode on iOS (fallback for the macOS test build).
    public init(uiColorCompatible name: SystemColorName) {
        #if canImport(UIKit)
        switch name {
        case .secondarySystemBackground: self = Color(uiColor: .secondarySystemBackground)
        case .systemBackground: self = Color(uiColor: .systemBackground)
        }
        #else
        self = Color.gray.opacity(0.15)
        #endif
    }
}

public enum SystemColorName {
    case secondarySystemBackground
    case systemBackground
}
