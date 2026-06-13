import SwiftUI

struct ExpandableFloatingMenuItem: Identifiable {
    let id: String
    let icon: String
    let label: String
    var isActive: Bool = false
    let action: () -> Void

    init(id: String, icon: String, label: String, isActive: Bool = false, action: @escaping () -> Void) {
        self.id = id
        self.icon = icon
        self.label = label
        self.isActive = isActive
        self.action = action
    }
}

/// Bottom-trailing expandable navigation menu shared by the iPhone root screen and
/// the iPad workspace. Items fan out vertically above the toggle button in array
/// order — feature-flagged items are simply included or omitted by the caller, so
/// there is no per-screen index arithmetic to keep in sync.
struct ExpandableFloatingMenu: View {
    @Binding var isExpanded: Bool
    let items: [ExpandableFloatingMenuItem]
    var itemSpacing: CGFloat = 54

    var body: some View {
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                itemButton(item)
                    .offset(y: isExpanded ? yOffset(forIndex: index) : 0)
                    .scaleEffect(isExpanded ? 1 : 0.1)
                    .opacity(isExpanded ? 1 : 0)
                    .animation(
                        .spring(response: 0.4, dampingFraction: 0.72).delay(animationDelay(forIndex: index)),
                        value: isExpanded
                    )
            }

            Button {
                withAnimation(.spring(duration: 0.22)) { isExpanded.toggle() }
            } label: {
                Image(systemName: isExpanded ? "xmark" : "line.3.horizontal")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Close Menu" : "Open Menu")
        }
    }

    private func yOffset(forIndex index: Int) -> CGFloat {
        -CGFloat(items.count - index) * itemSpacing
    }

    private func animationDelay(forIndex index: Int) -> Double {
        isExpanded
            ? Double(index) * 0.045
            : Double(items.count - 1 - index) * 0.03
    }

    private func itemButton(_ item: ExpandableFloatingMenuItem) -> some View {
        Button {
            item.action()
            withAnimation(.spring(duration: 0.22)) { isExpanded = false }
        } label: {
            Image(systemName: item.icon)
                .font(.system(size: 20))
                .foregroundStyle(item.isActive ? Color.accentColor : .secondary)
                .frame(width: 44, height: 44)
                .background(Color(.tertiarySystemFill))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.label)
    }
}
