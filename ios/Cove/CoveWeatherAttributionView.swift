import SwiftUI
import UIKit

/// The exact Apple-provided PNGs are persisted with the reply: offline history
/// never needs an unauthenticated image request or a substitute logo.
struct CoveWeatherAttributionView: View {
    let attribution: CoveWeatherAttribution
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if attribution.required {
            VStack(alignment: .leading, spacing: 2) {
                if let data = attribution.markData(dark: colorScheme == .dark),
                   let mark = UIImage(data: data) {
                    Image(uiImage: mark).resizable().scaledToFit()
                        .frame(width: 100, height: 24, alignment: .leading)
                        .accessibilityLabel("Apple Weather")
                } else {
                    Text("Apple Weather 标记不可用").font(.caption)
                }
                ForEach(attribution.safeLegalURLs, id: \.absoluteString) { url in
                    Link(destination: url) {
                        Text("天气数据来源").font(.caption)
                            .frame(minHeight: 44, alignment: .leading)
                    }.accessibilityHint("打开 Apple Weather 法律归属与数据来源")
                }
                if let date = attribution.sourceDate {
                    Text("北京 · 数据有效于 " + CoveWeatherAttribution.beijingTime(date))
                        .font(.caption2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(CoveStyle.secondaryText)
            .tint(CoveStyle.teal)
            .padding(.top, 6)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.weatherAttribution")
        }
    }
}
