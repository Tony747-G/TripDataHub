import SwiftUI
import CoreText

struct MaterialIconView: View {
    let codePoint: Int
    var size: CGFloat = 18
    var color: Color = .primary
    var fallbackSystemName: String = "questionmark.circle"

    var body: some View {
        Group {
            if let fontName = Self.resolvedMaterialFontName {
                Text(glyphText)
                    .font(.custom(fontName, size: size))
                    .lineLimit(1)
                    .minimumScaleFactor(1.0)
            } else {
                Image(systemName: fallbackSystemName)
                    .font(.system(size: size))
            }
        }
        .foregroundStyle(color)
        .accessibilityHidden(true)
    }

    private var glyphText: String {
        guard let scalar = UnicodeScalar(codePoint) else { return "?" }
        return String(Character(scalar))
    }

    private static let resolvedMaterialFontName: String? = {
        let urls: [URL?] = [
            Bundle.main.url(forResource: "MaterialIcons", withExtension: "ttf"),
            Bundle.main.url(forResource: "MaterialIcons", withExtension: "ttf", subdirectory: "Resources/Fonts")
        ]

        for maybeURL in urls {
            guard let url = maybeURL else { continue }

            var registrationError: Unmanaged<CFError>?
            _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &registrationError)

            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else {
                continue
            }

            for descriptor in descriptors {
                if let postScriptName = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String,
                   !postScriptName.isEmpty {
                    return postScriptName
                }
            }
        }
        return nil
    }()

    static var debugStatusLabel: String {
        if let name = resolvedMaterialFontName {
            return "Icons: Material (\(name))"
        }
        return "Icons: Fallback (SF Symbols)"
    }
}
