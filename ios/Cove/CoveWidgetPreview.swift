#if DEBUG
import Foundation

/// Explicit offline QA fixture. Never inserted in a connected conversation.
enum CoveWidgetPreview {
    static let text = #"""
    这是本地示例，不会上传。一起定个轻松的小计划：

    ```widget
    {"version":1,"id":"local-plan","state":{"step":1,"choice":"散步","note":"","minutes":20},"root":{"type":"Stack","props":{"spacing":8},"children":[
      {"type":"Stack","visible":{"op":"eq","args":[{"ref":"step"},1]},"children":[
        {"type":"Choice","props":{"label":"想做什么","bind":"choice","options":[{"label":"散步","value":"散步"},{"label":"读书","value":"读书"}]}},
        {"type":"Input","props":{"label":"补充一句","bind":"note","placeholder":"可选备注"}},
        {"type":"Slider","props":{"label":"分钟","bind":"minutes","min":5,"max":60,"step":5}},
        {"type":"Button","id":"next","props":{"label":"下一步","action":{"type":"set","values":{"step":2}}}}
      ]},
      {"type":"Transition","visible":{"op":"eq","args":[{"ref":"step"},2]},"props":{"key":{"ref":"step"}},"children":[
        {"type":"Metric","props":{"label":"计划时长","value":{"ref":"minutes"},"unit":"分钟"}},
        {"type":"Text","props":{"text":{"op":"concat","args":["选择：",{"ref":"choice"},"；备注：",{"ref":"note"}]}}},
        {"type":"Button","id":"back","props":{"label":"返回修改","action":{"type":"set","values":{"step":1}}}},
        {"type":"Button","id":"submit","props":{"label":"把计划告诉你","action":{"type":"send","text":{"op":"concat","args":["我想",{"ref":"choice"}," ",{"ref":"minutes"}," 分钟。",{"ref":"note"}]}}}}
      ]}
    ]}}
    ```
    卡片下方仍然是普通消息正文。
    """#
}
#endif
