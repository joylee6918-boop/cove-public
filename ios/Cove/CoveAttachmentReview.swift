import SwiftUI

struct CoveAttachmentDraft: Identifiable {
    let id = UUID()
    let files: [CoveOutgoingFile]
    let conversationID: String
    let caption: String
}

/// Selecting from a provider prepares a draft, never sends behind the user's
/// back. One explicit Send commits the ordered files and caption to the outbox.
struct CoveAttachmentReview: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: CoveStore
    let draft: CoveAttachmentDraft
    let send: ([CoveOutgoingFile], String) async -> Bool
    @State private var caption: String
    @State private var excluded: Set<Int> = []
    @State private var sending = false

    init(draft: CoveAttachmentDraft, send: @escaping ([CoveOutgoingFile], String) async -> Bool) {
        self.draft = draft
        self.send = send
        _caption = State(initialValue: draft.caption)
    }

    private var selected: [CoveOutgoingFile] {
        draft.files.enumerated().filter { !excluded.contains($0.offset) }.map(\.element)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("待发送 · \(selected.count) 个") {
                    ForEach(Array(draft.files.enumerated()), id: \.offset) { index, file in
                        if !excluded.contains(index) {
                            HStack(spacing: 12) {
                                Image(systemName: file.mime.hasPrefix("image/") ? "photo" : "doc")
                                    .foregroundStyle(CoveStyle.teal)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(file.filename).lineLimit(2)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { excluded.insert(index) } label: {
                                    Image(systemName: "minus.circle").frame(width: 44, height: 44)
                                }.buttonStyle(.plain).accessibilityLabel("移除 \(file.filename)")
                            }
                        }
                    }
                }
                Section("附言") {
                    TextField("添加说明…", text: $caption, axis: .vertical).lineLimit(2...6)
                }
                if let error = store.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .navigationTitle("发送附件").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .disabled(sending).accessibilityLabel("关闭附件预览")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    guard !sending else { return }
                    sending = true
                    Task {
                        if await send(selected, caption) { dismiss() }
                        sending = false
                    }
                } label: {
                    HStack { if sending { ProgressView() }; Text(sending ? "正在加入发件箱…" : "发送 \(selected.count) 个附件") }
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .disabled(sending || selected.isEmpty || !store.canSendMessages)
                .padding().background(.regularMaterial)
                .accessibilityIdentifier("attachments.confirmSend")
            }
        }
        .interactiveDismissDisabled(sending)
    }
}
