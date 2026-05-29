import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ProfileCard: View {
    let avatarImageData: Data
    let displayName: String
    var subtitle: String? = nil
    var showsChevron = false
    var avatarSize: CGFloat = 48

    var body: some View {
        HStack(spacing: 16) {
            ProfileAvatarView(imageData: avatarImageData, size: avatarSize)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }

            Spacer()

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ProfileAvatarView: View {
    let imageData: Data
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.14))
                .frame(width: size, height: size)

#if canImport(UIKit)
            if let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                placeholder
            }
#else
            placeholder
#endif
        }
        .overlay(
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private var placeholder: some View {
        Image(systemName: "person.crop.circle.fill")
            .font(.system(size: size * 0.7))
            .foregroundStyle(.secondary)
    }
}
