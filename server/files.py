"""Bounded attachment data, inert downloads and explicitly confined file exports."""
import base64
import binascii
import mimetypes
import os
import re
import stat
from pathlib import Path
from urllib.parse import quote

from storage import APIError

MAX_ATTACHMENT = 20 * 1024 * 1024
MAX_BODY = 29 * 1024 * 1024  # One base64 upload plus JSON metadata.
MAX_ATTACHMENTS = 10
TEXT_PER_FILE = 100_000
TEXT_TOTAL = 200_000
VISION_TOTAL = 20 * 1024 * 1024
MIME = re.compile(r'^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+$')
TEXT_SUFFIXES = {'.txt', '.md', '.markdown', '.html', '.htm', '.json', '.jsonl', '.xml', '.svg', '.csv', '.tsv', '.yaml', '.yml', '.toml', '.ini', '.log', '.css', '.js', '.jsx', '.ts', '.tsx', '.py', '.swift', '.rs', '.go', '.java', '.c', '.h', '.cpp', '.hpp', '.sh', '.sql', '.vue', '.svelte'}


def validate_file(filename, mime, data):
    if not isinstance(filename, str) or not filename or len(filename) > 255 or len(filename.encode('utf-8')) > 1024 or filename in ('.', '..'):
        raise APIError(400, '文件名无效')
    if '/' in filename or '\\' in filename or any(ord(c) < 32 or ord(c) == 127 for c in filename):
        raise APIError(400, '文件名无效')
    if not isinstance(mime, str) or len(mime) > 160 or not MIME.fullmatch(mime):
        raise APIError(400, 'MIME 必须为 type/subtype')
    if not isinstance(data, bytes):
        raise APIError(400, '文件内容无效')
    if len(data) > MAX_ATTACHMENT:
        raise APIError(413, '每个文件最多 20 MiB')
    return filename, mime.lower(), data


def decode_file(arguments):
    if not isinstance(arguments, dict):
        raise APIError(400, '文件参数无效')
    has_text, has_base64 = 'text' in arguments, 'dataBase64' in arguments
    if has_text == has_base64:
        raise APIError(400, '必须且只能提供 text 或 dataBase64')
    if has_text:
        text = arguments['text']
        if not isinstance(text, str) or len(text) > MAX_ATTACHMENT:
            raise APIError(413, '文件内容无效或超过 20 MiB')
        data = text.encode('utf-8')
    else:
        raw = arguments['dataBase64']
        if not isinstance(raw, str) or len(raw) > (MAX_ATTACHMENT + 2) // 3 * 4:
            raise APIError(413, '文件编码过大')
        try:
            data = base64.b64decode(raw, validate=True)
        except (ValueError, binascii.Error):
            raise APIError(400, '文件 Base64 无效')
    return validate_file(arguments.get('filename'), arguments.get('mime'), data)


def metadata(attachment):
    return {'id': attachment['id'], 'filename': attachment['filename'], 'mime': attachment['mime'],
            'size': len(attachment['data']), 'url': '/v1/attachments/' + attachment['id']}


def disposition(filename):
    fallback = re.sub(r'[^A-Za-z0-9_. -]', '_', filename) or 'download'
    return 'attachment; filename="' + fallback + '"; filename*=UTF-8\'\'' + quote(filename, safe='')


def vision_image(attachment):
    data, mime = attachment['data'], attachment['mime']
    return {'image/png': data.startswith(b'\x89PNG\r\n\x1a\n'), 'image/jpeg': data.startswith(b'\xff\xd8\xff'),
            'image/gif': data.startswith((b'GIF87a', b'GIF89a')), 'image/webp': data.startswith(b'RIFF') and data[8:12] == b'WEBP'}.get(mime, False)


def text_file(attachment):
    return attachment['mime'].startswith('text/') or attachment['mime'] in ('application/json', 'application/xml', 'application/javascript', 'application/x-yaml', 'application/toml') or Path(attachment['filename']).suffix.lower() in TEXT_SUFFIXES


def open_export_roots(setting):
    roots = []
    try:
        for raw in filter(None, setting.split(os.pathsep)):
            path = Path(raw).expanduser().resolve(strict=True)
            if not path.is_dir() or path in (Path('/'), Path.home(), Path('/etc'), Path('/root'), Path('/Users'), Path('/home')):
                raise ValueError('COVE_EXPORT_ROOTS must contain dedicated export directories')
            descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            roots.append((path, descriptor))
    except Exception:
        for _, descriptor in roots:
            os.close(descriptor)
        raise
    return roots


def export_file(arguments, roots):
    path = arguments.get('path') if isinstance(arguments, dict) else None
    if not isinstance(path, str) or not Path(path).is_absolute() or not roots:
        raise APIError(403, '仅允许配置的专用导出目录内绝对路径')
    try:
        resolved = Path(path).resolve(strict=True)
        for root, root_descriptor in roots:
            try:
                parts = resolved.relative_to(root).parts
            except ValueError:
                continue
            if not parts or any(part.startswith('.') for part in parts):
                raise APIError(403, '不能导出隐藏文件或目录')
            # Traverse relative to a pinned directory FD, never following child symlinks.
            descriptor = os.dup(root_descriptor)
            try:
                for part in parts[:-1]:
                    child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
                    os.close(descriptor); descriptor = child
                file_descriptor = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=descriptor)
                with os.fdopen(file_descriptor, 'rb') as source:
                    info = os.fstat(source.fileno())
                    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                        raise APIError(403, '只能导出普通文件，不能导出链接或特殊文件')
                    if info.st_size > MAX_ATTACHMENT:
                        raise APIError(413, '每个文件最多 20 MiB')
                    data = source.read(MAX_ATTACHMENT + 1)
                mime = arguments.get('mime') or mimetypes.guess_type(resolved.name)[0] or 'application/octet-stream'
                return validate_file(arguments.get('filename') or resolved.name, mime, data)
            finally:
                os.close(descriptor)
        raise APIError(403, '路径不在配置的专用导出目录内')
    except (OSError, RuntimeError, ValueError):
        raise APIError(403, '文件不可访问或不在安全导出范围')


CREATE_TOOL = {'name': 'cove_create_file', 'description': 'Create a downloadable file in the current Cove reply from exact UTF-8 text or Base64 bytes. It is committed as an attachment; no shell or HTML execution. Use this to deliver Markdown, HTML, source, JSON or generated binary files. Maximum 20 MiB per file, 10 reply attachments. Cove HTML preview supports inline CSS/JavaScript and embedded data assets, blocks remote resources/CDNs/network; generate self-contained HTML.',
               'inputSchema': {'type': 'object', 'properties': {'filename': {'type': 'string'}, 'mime': {'type': 'string'}, 'text': {'type': 'string'}, 'dataBase64': {'type': 'string'}}, 'required': ['filename', 'mime'], 'additionalProperties': False,
                               'oneOf': [{'required': ['text']}, {'required': ['dataBase64']}]}}
SEND_TOOL = {'name': 'cove_send_file', 'description': 'Attach an existing regular file from explicitly configured dedicated COVE_EXPORT_ROOTS only. Absolute path required. Hidden files, outside paths, links and system directories are refused. File bytes are committed into the current Cove reply. Does not run or render the file.',
             'inputSchema': {'type': 'object', 'properties': {'path': {'type': 'string'}, 'filename': {'type': 'string'}, 'mime': {'type': 'string'}}, 'required': ['path'], 'additionalProperties': False}}
STICKER_LIST_TOOL = {'name': 'cove_list_stickers', 'description': 'List your own persistent Cove sticker library (id, descriptive label and image metadata). Choose an appropriate existing sticker by label, then use cove_send_sticker. This never lists unshared user uploads.',
                     'inputSchema': {'type': 'object', 'properties': {}, 'additionalProperties': False}}
STICKER_SAVE_TOOL = {'name': 'cove_save_sticker', 'description': 'Save an image that 用户 has already sent in this Cove conversation into your own persistent sticker library. Use its attachmentID from Cove attachment context and a short accurate descriptive label for later selection. PNG/JPEG/GIF/WebP only; original animation bytes are preserved. Does not send a reply or access arbitrary files.',
                     'inputSchema': {'type': 'object', 'properties': {'attachmentID': {'type': 'string'}, 'label': {'type': 'string', 'minLength': 1, 'maxLength': 120}}, 'required': ['attachmentID', 'label'], 'additionalProperties': False}}
STICKER_SEND_TOOL = {'name': 'cove_send_sticker', 'description': 'Send a saved sticker from your own Cove sticker library as an image attachment in the current reply. Obtain stickerID from cove_list_stickers or cove_save_sticker. Exact original bytes, including GIF animation, are reused. No model turn or external message is started; this attaches only to the current active reply.',
                     'inputSchema': {'type': 'object', 'properties': {'stickerID': {'type': 'string'}}, 'required': ['stickerID'], 'additionalProperties': False}}
STICKER_TOOLS = [STICKER_LIST_TOOL, STICKER_SAVE_TOOL, STICKER_SEND_TOOL]
VOICE_SEND_TOOL = {'name': 'cove_send_voice', 'description': 'Generate one spoken MP3 from short reply text using the owner-configured MiniMax voice and attach it to this same active Cove reply. This is a paid, explicitly configured server action: use only when a voice reply is genuinely intended. It never accepts an API key or voice id, never clones a voice, and never starts another message or call.',
                   'inputSchema': {'type': 'object', 'properties': {'text': {'type': 'string', 'minLength': 1, 'maxLength': 2000}}, 'required': ['text'], 'additionalProperties': False}}
VOICE_TOOLS = [VOICE_SEND_TOOL]
FILE_TOOLS = [CREATE_TOOL, SEND_TOOL] + STICKER_TOOLS + VOICE_TOOLS

PULSE_NOTE_TOOL = {'name': 'cove_record_pulse_note', 'description': 'During a Pulse wake only, record a short, deliberately public-facing reflection and intent for the private Pulse timeline. This is not hidden reasoning and does not send a chat message or claim that an action ran.',
                   'inputSchema': {'type': 'object', 'properties': {
                       'thoughtSummary': {'type': 'string', 'minLength': 1, 'maxLength': 500},
                       'intent': {'type': 'string', 'minLength': 1, 'maxLength': 240}},
                       'required': ['thoughtSummary', 'intent'], 'additionalProperties': False}}
FILE_TOOLS.append(PULSE_NOTE_TOOL)

# Same current-turn capability bridge, no global health read.
from health_requests import HEALTH_TOOLS
FILE_TOOLS += HEALTH_TOOLS

from data_access import DATA_TOOLS
FILE_TOOLS += DATA_TOOLS

from personal_ledger import TOOLS as PERSONAL_LEDGER_TOOLS
FILE_TOOLS += PERSONAL_LEDGER_TOOLS

from collar import COLLAR_TOOLS
FILE_TOOLS += COLLAR_TOOLS

from toy_control import TOY_TOOLS
FILE_TOOLS += TOY_TOOLS

from memory_outbox import MEMORY_TOOLS
FILE_TOOLS += MEMORY_TOOLS

from device_actions import DEVICE_TOOLS
FILE_TOOLS += DEVICE_TOOLS

from travel_bridge import TRAVEL_TOOLS
FILE_TOOLS += TRAVEL_TOOLS

from weather_tools import WEATHER_TOOL
FILE_TOOLS.append(WEATHER_TOOL)

from wallet_tools import WALLET_TOOLS
FILE_TOOLS += WALLET_TOOLS
