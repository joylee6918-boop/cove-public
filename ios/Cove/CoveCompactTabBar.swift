import SwiftUI

/// A compact control strip; TabView still owns each page's navigation and state.
struct CoveCompactTabBar: View {
    @Binding var selection: Int
    private let items = [
        ("家", "house", "home"),
        ("心跳", "heart", "pulse"),
        ("对话", "bubble.left.and.bubble.right", "chat"),
        ("健康", "heart.text.square", "health"),
        ("设置", "gearshape", "settings")
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                let selected = selection == index
                Button {
                    selection = index
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: item.1)
                            .font(.system(size: 20, weight: .regular))
                            .symbolVariant(selected ? .fill : .none)
                            .frame(height: 22)
                        Text(item.0).font(.system(size: 10, weight: selected ? .semibold : .medium))
                    }
                    .foregroundStyle(selected ? CoveStyle.accentText : CoveStyle.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(selected ? CoveStyle.softAccent.opacity(0.55) : .clear, in: Capsule())
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.0)
                .accessibilityIdentifier("tab.\(item.2)")
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(4)
        .frame(maxWidth: 320)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(CoveStyle.border.opacity(0.65), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cove.tabBar")
    }
}
