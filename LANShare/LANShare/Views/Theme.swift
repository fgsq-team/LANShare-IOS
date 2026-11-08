import SwiftUI
import UIKit

// MARK: - 主题令牌 (Android: values/colors.xml + values-night/colors.xml + AppTheme.Emerald)

/// 一套完整的配色令牌，字段与 Android 的颜色资源一一对应
struct LPalette {
    let background: UIColor
    let surface: UIColor
    let surfaceVariant: UIColor
    let cardBackground: UIColor
    let cardStroke: UIColor
    let divider: UIColor

    let textPrimary: UIColor
    let textSecondary: UIColor
    let textTertiary: UIColor
    let itemText: UIColor
    let textSelect: UIColor
    let textNotSelect: UIColor

    let primary: UIColor
    let primaryDark: UIColor
    let primaryLight: UIColor
    let accent: UIColor
    let secondary: UIColor

    let toolbarBackground: UIColor
    let toolbarText: UIColor
    let buttonBackground: UIColor
    let buttonText: UIColor

    let chatBackground: UIColor
    let chatLeftBackground: UIColor
    let chatRightBackground: UIColor
    let chatLeftText: UIColor
    let chatRightText: UIColor
    let chatInfoText: UIColor
    let chatLeftInfoText: UIColor
    let chatRightInfoText: UIColor
    let chatLeftSuccess: UIColor
    let chatRightSuccess: UIColor

    let bottomBackground: UIColor
    let bottomText: UIColor
    let bottomSelectedText: UIColor
    let bottomIndicator: UIColor

    let icon: UIColor
    let iconSelected: UIColor
    let mediaText: UIColor
    let deviceInfoText: UIColor
    let fileIconBackground: UIColor

    let error: UIColor
    let success: UIColor
    let green: UIColor
    let limeGreen: UIColor
    let white: UIColor
    let ripple: UIColor
    let shadow: UIColor

    let battery0: UIColor
    let battery1: UIColor
    let battery2: UIColor
    let battery3: UIColor
    let battery4: UIColor
    let batteryCharging: UIColor
}

private func hex(_ value: String) -> UIColor {
    var text = value
    if text.hasPrefix("#") { text.removeFirst() }
    var raw: UInt64 = 0
    Scanner(string: text).scanHexInt64(&raw)
    let a: CGFloat, r: CGFloat, g: CGFloat, b: CGFloat
    if text.count == 8 {
        a = CGFloat((raw >> 24) & 0xFF) / 255
        r = CGFloat((raw >> 16) & 0xFF) / 255
        g = CGFloat((raw >> 8) & 0xFF) / 255
        b = CGFloat(raw & 0xFF) / 255
    } else {
        a = 1
        r = CGFloat((raw >> 16) & 0xFF) / 255
        g = CGFloat((raw >> 8) & 0xFF) / 255
        b = CGFloat(raw & 0xFF) / 255
    }
    return UIColor(red: r, green: g, blue: b, alpha: a)
}

extension LPalette {
    /// 光明 (AppTheme)
    static let light = LPalette(
        background: hex("F8F9FE"), surface: hex("FFFFFF"), surfaceVariant: hex("F0F2F8"),
        cardBackground: hex("FFFFFF"), cardStroke: hex("E8E8E8"), divider: hex("E8E8E8"),
        textPrimary: hex("1A1C1E"), textSecondary: hex("6B6B6B"), textTertiary: hex("9E9E9E"),
        itemText: hex("6B6B6B"), textSelect: hex("5B8DEF"), textNotSelect: hex("9E9E9E"),
        primary: hex("5B8DEF"), primaryDark: hex("3D6DD8"), primaryLight: hex("E8F0FE"),
        accent: hex("FF6B6B"), secondary: hex("7C5CFC"),
        toolbarBackground: hex("FFFFFF"), toolbarText: hex("1A1C1E"),
        buttonBackground: hex("5B8DEF"), buttonText: hex("FFFFFF"),
        chatBackground: hex("F8F9FE"), chatLeftBackground: hex("E0E5F0"), chatRightBackground: hex("5B8DEF"),
        chatLeftText: hex("1A1C1E"), chatRightText: hex("FFFFFF"),
        chatInfoText: hex("777777"), chatLeftInfoText: hex("999999"), chatRightInfoText: hex("C0C0C0"),
        chatLeftSuccess: hex("4CAF50"), chatRightSuccess: hex("C8E6C9"),
        bottomBackground: hex("FFFFFF"), bottomText: hex("9E9E9E"),
        bottomSelectedText: hex("5B8DEF"), bottomIndicator: hex("E8F0FE"),
        icon: hex("6B6B6B"), iconSelected: hex("5B8DEF"), mediaText: hex("6B6B6B"),
        deviceInfoText: hex("999999"), fileIconBackground: hex("FFFFFF"),
        error: hex("F44336"), success: hex("4CAF50"), green: hex("4CAF50"), limeGreen: hex("8BC34A"),
        white: hex("FFFFFF"), ripple: hex("1A000000"), shadow: hex("14000000"),
        battery0: hex("F44336"), battery1: hex("FF9800"), battery2: hex("FFC107"),
        battery3: hex("8BC34A"), battery4: hex("4CAF50"), batteryCharging: hex("4CAF50"))

    /// 暗黑 (values-night)
    static let dark = LPalette(
        background: hex("1A1C1E"), surface: hex("2D2F31"), surfaceVariant: hex("3C3E40"),
        cardBackground: hex("2D2F31"), cardStroke: hex("3C3E40"), divider: hex("3C3E40"),
        textPrimary: hex("E3E3E3"), textSecondary: hex("A8A8A8"), textTertiary: hex("757575"),
        itemText: hex("B0B0B0"), textSelect: hex("8AB4F8"), textNotSelect: hex("9E9E9E"),
        primary: hex("8AB4F8"), primaryDark: hex("1A1C1E"), primaryLight: hex("2A3648"),
        accent: hex("FF8A8A"), secondary: hex("B39DDB"),
        toolbarBackground: hex("2D2F31"), toolbarText: hex("E3E3E3"),
        buttonBackground: hex("8AB4F8"), buttonText: hex("1A1C1E"),
        chatBackground: hex("1A1C1E"), chatLeftBackground: hex("3C3E40"), chatRightBackground: hex("3D6DD8"),
        chatLeftText: hex("E3E3E3"), chatRightText: hex("FFFFFF"),
        chatInfoText: hex("B0B0B0"), chatLeftInfoText: hex("999999"), chatRightInfoText: hex("C0C0C0"),
        chatLeftSuccess: hex("81C784"), chatRightSuccess: hex("A5D6A7"),
        bottomBackground: hex("2D2F31"), bottomText: hex("757575"),
        bottomSelectedText: hex("8AB4F8"), bottomIndicator: hex("2A3648"),
        icon: hex("A8A8A8"), iconSelected: hex("8AB4F8"), mediaText: hex("A8A8A8"),
        deviceInfoText: hex("B0B0B0"), fileIconBackground: hex("FFFFFF"),
        error: hex("EF5350"), success: hex("81C784"), green: hex("81C784"), limeGreen: hex("AED581"),
        white: hex("FFFFFF"), ripple: hex("1FFFFFFF"), shadow: hex("29000000"),
        battery0: hex("EF5350"), battery1: hex("FFA726"), battery2: hex("FFEE58"),
        battery3: hex("9CCC65"), battery4: hex("66BB6A"), batteryCharging: hex("66BB6A"))

    /// 翠绿 (AppTheme.Emerald)；Android 该主题没有夜间变体，始终按浅色呈现
    static let emerald = LPalette(
        background: hex("F6FBF6"), surface: hex("FFFFFF"), surfaceVariant: hex("EDF7ED"),
        cardBackground: hex("FFFFFF"), cardStroke: hex("C8E6C9"), divider: hex("C8E6C9"),
        textPrimary: hex("1A1C1E"), textSecondary: hex("5F6368"), textTertiary: hex("9E9E9E"),
        itemText: hex("5F6368"), textSelect: hex("2E7D32"), textNotSelect: hex("9E9E9E"),
        primary: hex("2E7D32"), primaryDark: hex("1B5E20"), primaryLight: hex("E8F5E9"),
        accent: hex("FF8F00"), secondary: hex("00897B"),
        toolbarBackground: hex("FFFFFF"), toolbarText: hex("1A1C1E"),
        buttonBackground: hex("2E7D32"), buttonText: hex("FFFFFF"),
        chatBackground: hex("F6FBF6"), chatLeftBackground: hex("D8ECD8"), chatRightBackground: hex("2E7D32"),
        chatLeftText: hex("1A1C1E"), chatRightText: hex("FFFFFF"),
        chatInfoText: hex("757575"), chatLeftInfoText: hex("757575"), chatRightInfoText: hex("C0C0C0"),
        chatLeftSuccess: hex("388E3C"), chatRightSuccess: hex("A5D6A7"),
        bottomBackground: hex("FFFFFF"), bottomText: hex("9E9E9E"),
        bottomSelectedText: hex("2E7D32"), bottomIndicator: hex("E8F5E9"),
        icon: hex("5F6368"), iconSelected: hex("2E7D32"), mediaText: hex("5F6368"),
        deviceInfoText: hex("9E9E9E"), fileIconBackground: hex("FFFFFF"),
        error: hex("D32F2F"), success: hex("388E3C"), green: hex("4CAF50"), limeGreen: hex("8BC34A"),
        white: hex("FFFFFF"), ripple: hex("1A000000"), shadow: hex("14000000"),
        battery0: hex("F44336"), battery1: hex("FF9800"), battery2: hex("FFC107"),
        battery3: hex("8BC34A"), battery4: hex("4CAF50"), batteryCharging: hex("4CAF50"))
}

/// 主题解析：跟随系统时按当前 trait 在光明/暗黑之间切换
enum LTheme {
    static var mode: ThemeMode { LSettings.shared.themeMode }

    static func palette(for traits: UITraitCollection) -> LPalette {
        switch mode {
        case .light: return .light
        case .dark: return .dark
        case .emerald: return .emerald
        case .followSystem: return traits.userInterfaceStyle == .dark ? .dark : .light
        }
    }
}

/// 视图片引用令牌：每次访问都返回一个随 trait 解析的动态颜色
enum LColor {
    private static func dyn(_ key: KeyPath<LPalette, UIColor>) -> Color {
        Color(uiColor: UIColor { traits in LTheme.palette(for: traits)[keyPath: key] })
    }

    static var background: Color { dyn(\.background) }
    static var surface: Color { dyn(\.surface) }
    static var surfaceVariant: Color { dyn(\.surfaceVariant) }
    static var cardBackground: Color { dyn(\.cardBackground) }
    static var cardStroke: Color { dyn(\.cardStroke) }
    static var divider: Color { dyn(\.divider) }

    static var textPrimary: Color { dyn(\.textPrimary) }
    static var textSecondary: Color { dyn(\.textSecondary) }
    static var textTertiary: Color { dyn(\.textTertiary) }
    static var itemText: Color { dyn(\.itemText) }
    static var textSelect: Color { dyn(\.textSelect) }
    static var textNotSelect: Color { dyn(\.textNotSelect) }

    static var primary: Color { dyn(\.primary) }
    static var primaryDark: Color { dyn(\.primaryDark) }
    static var primaryLight: Color { dyn(\.primaryLight) }
    static var accent: Color { dyn(\.accent) }
    static var secondary: Color { dyn(\.secondary) }

    static var toolbarBackground: Color { dyn(\.toolbarBackground) }
    static var toolbarText: Color { dyn(\.toolbarText) }
    static var buttonBackground: Color { dyn(\.buttonBackground) }
    static var buttonText: Color { dyn(\.buttonText) }

    static var chatBackground: Color { dyn(\.chatBackground) }
    static var chatLeftBackground: Color { dyn(\.chatLeftBackground) }
    static var chatRightBackground: Color { dyn(\.chatRightBackground) }
    static var chatLeftText: Color { dyn(\.chatLeftText) }
    static var chatRightText: Color { dyn(\.chatRightText) }
    static var chatInfoText: Color { dyn(\.chatInfoText) }
    static var chatLeftInfoText: Color { dyn(\.chatLeftInfoText) }
    static var chatRightInfoText: Color { dyn(\.chatRightInfoText) }
    static var chatLeftSuccess: Color { dyn(\.chatLeftSuccess) }
    static var chatRightSuccess: Color { dyn(\.chatRightSuccess) }

    static var bottomBackground: Color { dyn(\.bottomBackground) }
    static var bottomText: Color { dyn(\.bottomText) }
    static var bottomSelectedText: Color { dyn(\.bottomSelectedText) }
    static var bottomIndicator: Color { dyn(\.bottomIndicator) }

    static var icon: Color { dyn(\.icon) }
    static var iconSelected: Color { dyn(\.iconSelected) }
    static var mediaText: Color { dyn(\.mediaText) }
    static var deviceInfoText: Color { dyn(\.deviceInfoText) }
    static var fileIconBackground: Color { dyn(\.fileIconBackground) }

    static var error: Color { dyn(\.error) }
    static var success: Color { dyn(\.success) }
    static var green: Color { dyn(\.green) }
    static var limeGreen: Color { dyn(\.limeGreen) }
    static var ripple: Color { dyn(\.ripple) }
    static var shadow: Color { dyn(\.shadow) }
}

// MARK: - 形状 (Android: drawable/*.xml 圆角)

/// 四角半径不同的气泡，对应 chat_left_bg / chat_right_bg 的 TL4 TR18 BL18 BR18
struct BubbleShape: Shape {
    var topLeft: CGFloat
    var topRight: CGFloat
    var bottomLeft: CGFloat
    var bottomRight: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRight, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - topRight, y: rect.minY + topRight), radius: topRight,
                    startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
        path.addArc(center: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY - bottomRight), radius: bottomRight,
                    startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY - bottomLeft), radius: bottomLeft,
                    startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeft))
        path.addArc(center: CGPoint(x: rect.minX + topLeft, y: rect.minY + topLeft), radius: topLeft,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

// MARK: - 通用组件 (Android: MaterialCardView / button_background / chip_background)

/// 卡片容器：对应 MaterialCardView 的 radius + surface 底 + 1dp 描边
struct LCard<Content: View>: View {
    var radius: CGFloat = 16
    var background: Color = LColor.surface
    var stroke: Color? = LColor.cardStroke
    var padding: CGFloat = 0
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(background))
            .overlay(stroke.map {
                RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder($0, lineWidth: 1)
            })
    }
}

/// 主按钮：Android button_background（12dp 圆角，按下 primaryDark）
struct LPrimaryButton: View {
    let title: String
    var radius: CGFloat = 12
    var action: () -> Void

    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(LColor.buttonText)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(pressed ? LColor.primaryDark : LColor.buttonBackground))
        }
        .buttonStyle(LPressButtonStyle(pressed: $pressed))
    }
}

/// 文字按钮：Android TextButton，无底色
struct LTextButton: View {
    let title: String
    var tint: Color = LColor.primary
    var action: () -> Void

    init(_ title: String, tint: Color = LColor.primary, action: @escaping () -> Void) {
        self.title = title
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 15)).foregroundStyle(tint)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct LPressButtonStyle: ButtonStyle {
    @Binding var pressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, value in pressed = value }
    }
}

/// 按压缩放/染色反馈，替代 Android 的 focused_background + ripple
struct LPressHighlight: ViewModifier {
    @State private var pressed = false

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(pressed ? LColor.primaryLight : Color.clear)
        )
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in pressed = true }
            .onEnded { _ in pressed = false })
    }
}

extension View {
    /// Android: ?android:attr/selectableItemBackground + focused_background
    func lPressHighlight() -> some View { modifier(LPressHighlight()) }
}
