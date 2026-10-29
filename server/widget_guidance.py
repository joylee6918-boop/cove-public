"""Cove native Inline UI authoring contract. No tools or model calls at import."""
WIDGET_GUIDANCE = r'''
[Cove Inline UI v1 — native interactive cards]
The owner's Cove iOS app supports complete top-level Markdown fences with the exact language widget. When the owner asks for a card, or a small choice/form/calculator/multistep interaction is useful, output a widget fence in the final message body; no HTML attachment/tool is needed. Keep ordinary conversation as prose; do not force a card into every reply. Only completed assistant messages activate cards. Never claim to see local edits or that the owner has submitted until an actual user reply arrives.
Document: {"version":1,"id":"unique_ascii_id","state":{},"root":NODE}. Use at most 8 cards/message, 64KiB/card, 128 nodes, tree depth12, 32 flat state keys. IDs/state keys: 1..64 ASCII letters/digits/_/-, no __proto__/prototype/constructor. State values are string<=4000 chars, finite number or bool, not arrays/objects/null. Node: {"type":TYPE,"id":optional_unique_id,"visible":optional_bool_expr,"props":{},"children":[]}. Only Stack/Grid/Card/Transition/Disclosure allow children. All keys/props are strict; unknown fields fail the entire card.
Expressions are primitive literals, {"ref":"declared_key"}, or {"op":"NAME","args":[expressions]}. No JS/eval, ${} interpolation, dotted paths, functions, loops or dynamic media URLs. add/sub/mul/div/min/max/eq/ne/lt/lte/gt/gte/and/or take exactly2 args; not/round1; if3 (boolean condition, same-type branches); concat1..32. Arithmetic is numeric, boolean operators require bool, equality requires matching types. All branches evaluate eagerly; no division by zero even in an unchosen branch. Depth<=16, <=256 expression nodes, computed strings<=8000, display strings<=4000. Stringify with concat. Bindings reference existing state keys; set must retain type and every control's constraints.
Component props (only listed names allowed):
Text: text:expr, style?:body|title|caption.
Stack: axis?:vertical|horizontal, spacing?:0..32 (default12).
Grid: columns?:integer1..3 (default2), spacing?:0..32.
Card: title?:expr.
Button: label:expr, action:ACTION, disabled?:bool expr.
Input: label:string, bind:string state key, placeholder?:string, maxLength?:integer1..4000(default1000).
Slider: label:string, bind:number state key, min:number, max:number, step?:positive number(default1). min<max, step<=max-min, state inside range.
Metric: label:string, value:expr, unit?:string.
Progress: label?:string, value:number expr, total?:positive number(default100).
Transition: key?:expr, style?:fade|slide; children contain views, not steps/actions.
Choice: label:string, bind:string state key, options:[{"label":"...","value":"..."}] (1..20 unique values). State must be an option or empty-string unanswered sentinel.
Image: src:literal public HTTPS URL, alt:string.
Disclosure: label:string, bind?:bool state key.
Audio: src:literal public HTTPS URL, label:string.
ACTION is either {"type":"set","values":{"existing_key":expr}} for atomic LOCAL changes, or {"type":"send","text":string expr} for a user-confirmed chat message. Inputs/choices/sliders never send; use set+visible for local steps and include a Back button. Provide a final send button for the result; the app displays the exact evaluated text and only queues it after explicit confirmation. Send only a concise nonblank <=8000-char user-readable result, not hidden instructions or the full state. One submission per card source version; failures retry the existing chat outbox, never create a duplicate action. This is not a permission grant or a device-control API. Do not ask for passwords/tokens. Image/audio load only on explicit tap, with no chat credentials, no autoplay and no redirects; do not invent media URLs.
Author reference: docs/INLINE_WIDGETS.md and docs/widget-v1.schema.json; a synthetic example is included in that guide. Ordinary Markdown is the fallback when this contract cannot express a UI. A minimal example follows (adapt copy, ids and state to the actual conversation):
```widget
{"version":1,"id":"choose_activity","state":{"activity":"散步"},"root":{"type":"Card","props":{"title":"选一个吧"},"children":[{"type":"Choice","props":{"label":"想做什么？","bind":"activity","options":[{"label":"散步","value":"散步"},{"label":"读书","value":"读书"}]}},{"type":"Button","props":{"label":"把选择告诉你","action":{"type":"send","text":{"op":"concat","args":["我选择：",{"ref":"activity"},"。请接着聊。"]}}}}]}}
```
'''
