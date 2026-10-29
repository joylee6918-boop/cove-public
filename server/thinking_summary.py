"""Display-only Codex summaries. Never read raw reasoning content/text."""

MAX_SUMMARY_CHARS = 32000
MAX_SUMMARY_ITEMS = 128


class ThinkingSummary:
    def __init__(self):
        self.items = {}

    def observe(self, method, params):
        # Completed snapshots are authoritative, avoiding duplicate streamed deltas.
        if method == 'item/completed':
            candidates = [params.get('item', {})]
        elif method == 'turn/completed':
            candidates = params.get('turn', {}).get('items', [])
        else:
            return None
        changed = False
        for item in candidates:
            if not isinstance(item, dict) or item.get('type') != 'reasoning':
                continue
            key, parts = item.get('id'), item.get('summary')
            if not isinstance(key, str) or not key or not isinstance(parts, list):
                continue
            if key not in self.items and len(self.items) >= MAX_SUMMARY_ITEMS:
                continue
            # Explicit public summary is the ONLY source, including when empty.
            remaining = MAX_SUMMARY_CHARS
            bounded = []
            for part in parts:
                if isinstance(part, str) and part.strip() and remaining > 0:
                    value = part.strip()[:remaining]
                    bounded.append(value)
                    remaining -= len(value) + 2
            text = '\n\n'.join(bounded)[:MAX_SUMMARY_CHARS]
            if self.items.get(key) != text:
                self.items[key] = text
                changed = True
        if changed:
            return '\n\n'.join(t for t in self.items.values() if t)[:MAX_SUMMARY_CHARS]
        return None
