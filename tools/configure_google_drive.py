#!/usr/bin/env python3
"""Configure public Google iOS client identifiers for a local Xcode build."""
import argparse
import os
from pathlib import Path
import re
import tempfile


def configure(client_id: str, output: Path) -> None:
    client_id = client_id.strip()
    suffix = '.apps.googleusercontent.com'
    if (not re.fullmatch(r'[A-Za-z0-9-]+\.apps\.googleusercontent\.com', client_id)
            or 'YOUR' in client_id.upper()):
        raise ValueError('Paste the full iOS OAuth client ID ending in .apps.googleusercontent.com.')
    if output.is_symlink():
        raise ValueError('The configuration is a symbolic link; edit its target explicitly instead.')
    values = {
        'GOOGLE_IOS_CLIENT_ID': client_id,
        'GOOGLE_REVERSED_CLIENT_ID': 'com.googleusercontent.apps.' + client_id[:-len(suffix)],
    }
    existing = output.read_text() if output.exists() else '// Public Google iOS client identifiers. No client secret or tokens.\n'
    lines = existing.splitlines()
    for name, value in values.items():
        matches = [i for i, line in enumerate(lines) if re.match(r'^\s*' + name + r'\s*=', line)]
        if len(matches) > 1:
            raise ValueError(f'Multiple {name} entries found. Original file preserved; remove duplicates first.')
        if matches:
            lines[matches[0]] = f'{name} = {value}'
        else:
            lines.append(f'{name} = {value}')
    contents = '\n'.join(lines) + '\n'
    output.parent.mkdir(parents=True, exist_ok=True)
    if contents == existing and output.exists():
        return
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', dir=output.parent, delete=False) as stream:
            temporary = stream.name
            stream.write(contents)
        os.replace(temporary, output)
    finally:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('client_id', nargs='?', help='Public iOS OAuth client ID; never a client secret.')
    parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parents[1] / 'ios' / 'GoogleDrive.local.xcconfig')
    args = parser.parse_args()
    try:
        client_id = args.client_id or input('Paste your Google iOS OAuth client ID: ')
        configure(client_id, args.output)
    except (ValueError, OSError, EOFError) as error:
        parser.exit(1, f'Configuration not saved: {error}\n')
    print('Google iOS client ID and callback scheme configured locally.')
    print('Confirm that the OAuth client uses the same bundle identifier as Xcode, then build/run with Cmd+R.')


if __name__ == '__main__':
    main()
