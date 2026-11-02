"""One-time local index cleanup. Keeps the actual keystore file on disk."""
import argparse
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true', help='Update .gitignore and the Git index')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    result = subprocess.run(['git', '-C', str(root), 'rev-parse', '--show-toplevel'],
                            check=True, capture_output=True, text=True)
    if Path(result.stdout.strip()).resolve() != root:
        raise SystemExit('Run this tool from its location in the repository tool/ directory.')
    key = 'android/app/keystore.jks'
    tracked = subprocess.run(['git', '-C', str(root), 'ls-files', '--error-unmatch', '--', key],
                             capture_output=True).returncode == 0
    if not args.apply:
        print('Keystore tracked:', tracked)
        print('Use --apply to untrack it and ignore local signing material. The file is kept.')
        return
    ignore = root / '.gitignore'
    content = ignore.read_text(encoding='utf-8') if ignore.exists() else ''
    rules = ['/android/app/keystore.jks', '/android/local.properties']
    missing = [rule for rule in rules if rule not in content.splitlines()]
    if missing:
        ignore.write_text(content.rstrip('\n') + '\n\n# Local signing material\n' +
                          '\n'.join(missing) + '\n', encoding='utf-8')
    if tracked:
        # No -f, no history rewriting, no deletion of the local key file.
        subprocess.run(['git', '-C', str(root), 'rm', '--cached', '--', key], check=True)
    print('Local key preserved; tracking removed. Historical exposure is not revoked.')


if __name__ == '__main__':
    main()
