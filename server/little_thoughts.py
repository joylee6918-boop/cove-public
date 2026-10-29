"""An explicitly authored public aside, never a reasoning-summary source."""
import re

MAX_THOUGHT_CHARS = 1000
GUIDANCE = '''
[Cove little thoughts]
Every ordinary visible reply to the user includes one brief, intentionally public
aside in the same final response. This is user-facing authored content, not hidden
reasoning or a transcript of an internal mental process. Keep it consistent with the
main reply and the operator's configured assistant style. Do not invent personal
history, feelings or completed actions. All essential answers, warnings and action
confirmations belong in the main reply.

Usually write the aside in one or two natural sentences. Its brevity does not limit
the main reply. Preserve normal Markdown and widget blocks.
Append exactly one top-level fenced block at the very end of every ordinary visible
reply:
```cove_little_thoughts
Your plain-text aside here, in the conversation's language.
```
This transport field is rendered as a collapsed “little thoughts” card. Maximum
1000 characters. Compose it in the same response, with no extra model or tool call.
Omit it for silent wakes, handoff bookkeeping and structured-only outputs.
'''

_FENCE = re.compile(r'^ {0,3}(`{3,}|~{3,})([^\r\n]*)[\r\n]*$')


def split_reply(text):
    """Remove reserved top-level fields; only one closed trailing field is valid.

    Ordinary/nested example fences and widget blocks are kept byte-for-byte.
    Incomplete/oversized/duplicate fields are discarded, not put in chat body.
    """
    lines = text.splitlines(keepends=True)
    body, fields = [], []
    fence = None
    reserved = False
    parts = []
    last_field_end = -1
    for index, line in enumerate(lines):
        match = _FENCE.match(line)
        if fence is None:
            if match:
                marker, info = match.groups()
                fence = marker
                reserved = info.strip() == 'cove_little_thoughts'
                if reserved:
                    parts = []
                    continue
            body.append(line)
        else:
            closes = bool(match and match.group(1)[0] == fence[0]
                          and len(match.group(1)) >= len(fence)
                          and not match.group(2).strip())
            if reserved:
                if closes:
                    fields.append(''.join(parts).strip())
                    last_field_end = index
                else:
                    parts.append(line)
            else:
                body.append(line)
            if closes:
                fence = None
                reserved = False
    if not fields and not reserved:
        return text, None
    thought = None
    if (not reserved and len(fields) == 1 and fields[0]
            and len(fields[0]) <= MAX_THOUGHT_CHARS
            and not ''.join(lines[last_field_end + 1:]).strip()):
        thought = fields[0]
    return ''.join(body).rstrip(), thought
