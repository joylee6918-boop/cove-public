import Foundation
import UIKit

@MainActor
enum CoveRichPreview {
    static let markdown = """
    # 把日常留在 Cove

    **粗体的认真**、*斜体的悄悄话*、~~划掉的小计划~~，还有 `inline code`。

    ## 今天的小清单

    - 把照片带回来
      - 留下拍摄时的心情
    - 保存一份 HTML

    1. 先打开文件
    2. 再慢慢看

    - [x] Markdown 排版
    - [ ] 一起试用

    > 不急，我们接着说。
    >
    > 这是一段引用。

    ### 代码也好好放着

    ```swift
    let place = "Cove"
    func hello(_ name: String) {
        print("Hello, \\(name). This is a deliberately long line for checking horizontal code scrolling without widening the chat bubble.")
    }
    hello("用户")
    ```

    | 文件 | 用途 | 状态 |
    | :--- | :---: | ---: |
    | 照片.png | 回忆 | 已保存 |
    | 小页面.html | 交互预览 | 可查看 |

    ---

    [Apple 开发者文档](https://developer.apple.com/documentation/)

    <script>这段原始 HTML 不会在聊天里执行。</script>
    """

    static let html = """
    <!doctype html><html lang="zh"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Cove 示例页面</title><style>body{font:20px -apple-system,sans-serif;padding:28px;background:#fff0f5;color:#36232f}button{font:inherit;background:#a82e63;color:white;border:0;border-radius:12px;padding:14px}pre{white-space:pre-wrap}</style>
    <h1>Cove 小页面</h1><p>这是附件示例，可以保存到“文件”。</p>
    <button id="reply" onclick="this.textContent='按钮已响应'">点击回应</button>
    <p>页面的交互在本机运行。</p>
    </html>
    """

    static func files() -> [String: Data] {
        let picture = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 360)).pngData { context in
            UIColor(red: 0.66, green: 0.18, blue: 0.39, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
            ("Cove · 示例图片" as NSString).draw(at: CGPoint(x: 60, y: 145), withAttributes: [.font: UIFont.systemFont(ofSize: 44, weight: .medium), .foregroundColor: UIColor.white])
        }
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { context in
            context.beginPage()
            ("Cove 示例 PDF\n\n这是一份用于验证预览和分享的文件。" as NSString).draw(in: CGRect(x: 45, y: 65, width: 505, height: 650), withAttributes: [.font: UIFont.systemFont(ofSize: 24), .foregroundColor: UIColor.black])
        }
        return ["/preview-attachments/html": Data(html.utf8), "/preview-attachments/image": picture, "/preview-attachments/pdf": pdf]
    }
}
