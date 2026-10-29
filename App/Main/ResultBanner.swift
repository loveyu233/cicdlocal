import SwiftUI

struct ResultBanner: View {
    let message: String
    let failed: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: failed ? "xmark.octagon.fill" : "checkmark.seal.fill")
                .foregroundStyle(failed ? Color.red : Color.green)
            Text(message)
                .textSelection(.enabled)
                // 窗口测量最小宽度时不能按全文无限增高，否则会反向撑大 NSWindow。
                .lineLimit(3)
                .truncationMode(.tail)
                .help(message)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("拷贝", systemImage: "doc.on.doc") { copyToPasteboard(message) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("拷贝这段说明")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background((failed ? Color.red : Color.green).opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stage-result")
    }
}
