"""Additive native CLI launch profile; never rewrite the base user config."""
import hashlib
import json
import os
import stat
import uuid
from pathlib import Path


def launch_profile(home, mcp_config, *, model=None, effort=None,
                   model_provider=None, approval_policy='on-request', sandbox='read-only'):
    home = Path(home)
    if not home.is_absolute() or home != home.resolve(strict=True):
        raise ValueError('explicit canonical Codex home required')
    base = home / 'config.toml'
    info = base.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_size > 256 * 1024:
        raise ValueError('base native config is not private')
    base_hash = hashlib.sha256(base.read_bytes()).hexdigest()
    server = mcp_config['mcp_servers.cove_files']
    if set(server.get('env', {})) != {'COVE_FILE_CAPABILITY_PATH'}:
        raise ValueError('native launch profile must contain a capability path, not credentials')
    if approval_policy not in ('untrusted', 'on-request', 'never') or sandbox not in ('read-only', 'workspace-write'):
        raise ValueError('unsupported Cove approval/sandbox mode')
    quote = lambda value: json.dumps(value, ensure_ascii=False)
    lines = ['approval_policy = ' + quote(approval_policy), 'sandbox_mode = ' + quote(sandbox)]
    for key, value in [('model', model), ('model_reasoning_effort', effort), ('model_provider', model_provider)]:
        if value is not None:
            if not isinstance(value, str) or not value or len(value) > 120 or any(ord(c) < 32 for c in value):
                raise ValueError('invalid native model configuration')
            lines.append(key + ' = ' + quote(value))
    lines += ['', '[mcp_servers.cove_files]', 'command = ' + quote(server['command']),
              'args = ' + quote(server['args']), 'enabled = true', 'required = true',
              '', '[mcp_servers.cove_files.env]',
              'COVE_FILE_CAPABILITY_PATH = ' + quote(server['env']['COVE_FILE_CAPABILITY_PATH'])]
    data = ('\n'.join(lines) + '\n').encode()
    name = 'cove_' + uuid.uuid4().hex
    path = home / (name + '.config.toml')
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    return {'config_sha256': base_hash, 'profile_name': name,
            'profile_sha256': hashlib.sha256(data).hexdigest()}
