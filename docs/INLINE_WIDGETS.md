# Native Inline UI v1

Cove renders completed assistant messages containing a top-level Markdown fence with the exact language `widget`. This is a native declarative card, not JavaScript, HTML, a remote website or hidden tool execution.

The complete authoring rules are in [`server/widget_guidance.py`](../server/widget_guidance.py); the structural schema is [`widget-v1.schema.json`](widget-v1.schema.json). Client validation and typed expression rules in `CoveWidget.swift` are authoritative; JSON Schema alone does not check all expression/permission constraints.

```widget
{"version":1,"id":"sample_choice","state":{"choice":"walk"},"root":{"type":"Card","props":{"title":"Synthetic example"},"children":[{"type":"Choice","props":{"label":"Activity","bind":"choice","options":[{"label":"Walk","value":"walk"},{"label":"Read","value":"read"}]}},{"type":"Button","props":{"label":"Share selection","action":{"type":"send","text":{"op":"concat","args":["My selection: ",{"ref":"choice"}]}}}}]}}
```

- Only completed assistant cards activate; malformed/unsupported content must not execute.
- State keys/types and component properties are strict. No eval, scripts, object traversal, secret fields or dynamic media URLs.
- Inputs and local `set` actions stay on the device. They do not send messages or grant data/device permission.
- `send` displays the evaluated text and requires explicit user confirmation. Retries use the existing durable outbox, not a new action each time.
- Media is literal public HTTPS only, loaded on explicit tap without chat credentials, autoplay or redirects. Do not invent source URLs.
- Limits include 8 cards/message, 64 KiB/card, 128 nodes, depth 12 and 32 flat state keys. Unsupported UI falls back to ordinary Markdown.

All content above is synthetic. No external service or private user data is required to render the sample.
