#!/usr/bin/env python3
import json
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path


def run(cmd):
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
        out = (proc.stdout or proc.stderr or '').strip()
        return {
            'ok': proc.returncode == 0,
            'code': proc.returncode,
            'output': out,
        }
    except FileNotFoundError:
        return {'ok': False, 'code': 127, 'output': 'command not found'}


def read_text(path):
    try:
        return Path(path).read_text()
    except Exception:
        return None


def parse_ruby_version(repo):
    text = read_text(repo / '.ruby-version')
    return text.strip() if text else None


def parse_bundler_version(repo):
    lock = read_text(repo / 'Gemfile.lock')
    if not lock:
        return None
    m = re.search(r'^BUNDLED WITH\n\s+([^\n]+)', lock, flags=re.M)
    return m.group(1).strip() if m else None


def parse_node_hint(repo):
    dockerfile = read_text(repo / '.devcontainer' / 'Dockerfile') or ''
    m = re.search(r'setup_(\d+)\.x', dockerfile)
    if m:
        return f"{m.group(1)}.x"
    return None


def detect_virtualization():
    evidence = []
    kind = None

    if shutil.which('systemd-detect-virt'):
        res = run(['systemd-detect-virt'])
        if res['ok'] and res['output']:
            kind = res['output'].splitlines()[0].strip()
            evidence.append(f"systemd-detect-virt={kind}")

    if Path('/.dockerenv').exists():
        evidence.append('/.dockerenv present')
        kind = kind or 'docker'

    cgroup = read_text('/proc/1/cgroup') or ''
    cgroup_lower = cgroup.lower()
    for token, label in [('docker', 'docker'), ('containerd', 'container'), ('kubepods', 'kubernetes'), ('lxc', 'lxc')]:
        if token in cgroup_lower:
            evidence.append(f'/proc/1/cgroup mentions {token}')
            kind = kind or label
            break

    cpuinfo = read_text('/proc/cpuinfo') or ''
    if 'hypervisor' in cpuinfo.lower():
        evidence.append('/proc/cpuinfo includes hypervisor flag')
        kind = kind or 'vm'

    product_name = read_text('/sys/class/dmi/id/product_name')
    if product_name:
        pn = product_name.strip()
        lowered = pn.lower()
        if any(x in lowered for x in ['kvm', 'virtual', 'vmware', 'virtualbox', 'firecracker']):
            evidence.append(f'product_name={pn}')
            kind = kind or 'vm'

    virtualized = bool(evidence)
    return {
        'virtualized': virtualized,
        'kind': kind or ('unknown' if virtualized else 'none'),
        'evidence': evidence,
    }


def disk_usage(paths):
    results = {}
    for p in paths:
        res = run(['df', '-h', p])
        results[p] = res['output']
    return results


def du(path):
    res = run(['du', '-sh', str(path)])
    return res['output']


def version_for(cmd, args):
    if not shutil.which(cmd):
        return {'present': False, 'version': None}
    res = run([cmd] + args)
    out = res['output'].splitlines()[0] if res['output'] else ''
    return {'present': True, 'version': out}


def recommend(virt, ruby, bundler, node, psql, redis, ruby_req, bundler_req, node_hint):
    missing = []
    if not ruby['present']:
        missing.append('Ruby')
    if not bundler['present']:
        missing.append('Bundler')
    if not psql['present']:
        missing.append('PostgreSQL client')
    if not redis['present']:
        missing.append('Redis server')

    strategy = 'lean-in-place-bootstrap' if virt['virtualized'] else 'prefer-devcontainer'

    rationale = []
    if virt['virtualized']:
        rationale.append('Detected a virtualized/containerized environment, so reusing the current runtime is usually simpler than nesting devcontainers.')
    else:
        rationale.append('No clear virtualization/container evidence detected, so the repo devcontainer is a strong default for reproducible setup on a normal host.')

    if missing:
        rationale.append('Missing components: ' + ', '.join(missing) + '.')
    else:
        rationale.append('Core toolchain looks present already.')

    if ruby_req and (not ruby['present'] or ruby_req not in (ruby['version'] or '')):
        rationale.append(f'Repo expects Ruby {ruby_req}.')
    if bundler_req and (not bundler['present'] or bundler_req not in (bundler['version'] or '')):
        rationale.append(f'Lockfile expects Bundler {bundler_req}.')
    if node_hint and node['present'] and node_hint.split('.')[0] not in (node['version'] or ''):
        rationale.append(f'Repo devcontainer references Node {node_hint}; current host differs, which is drift to note but not necessarily fix immediately.')

    return strategy, rationale, missing


def markdown_report(data):
    lines = []
    lines.append('# Sure build environment audit')
    lines.append('')
    lines.append('## Host classification')
    lines.append('')
    lines.append(f"- Virtualized: **{'yes' if data['virtualization']['virtualized'] else 'no'}**")
    lines.append(f"- Kind: **{data['virtualization']['kind']}**")
    if data['virtualization']['evidence']:
        lines.append('- Evidence:')
        for item in data['virtualization']['evidence']:
            lines.append(f'  - {item}')
    else:
        lines.append('- Evidence: none detected')
    lines.append('')
    lines.append('## Recommendation')
    lines.append('')
    lines.append(f"- Strategy: **{data['recommendation']['strategy']}**")
    for item in data['recommendation']['rationale']:
        lines.append(f'- {item}')
    lines.append('')
    lines.append('## Toolchain')
    lines.append('')
    for key in ['ruby', 'bundler', 'node', 'npm', 'psql', 'redis_server', 'git', 'curl']:
        item = data['tools'][key]
        name = key.replace('_', '-')
        if item['present']:
            lines.append(f"- {name}: `{item['version']}`")
        else:
            lines.append(f"- {name}: **missing**")
    lines.append('')
    lines.append('## Repo expectations')
    lines.append('')
    lines.append(f"- Ruby required: `{data['repo']['ruby_required'] or 'unknown'}`")
    lines.append(f"- Bundler required: `{data['repo']['bundler_required'] or 'unknown'}`")
    lines.append(f"- Devcontainer Node hint: `{data['repo']['node_hint'] or 'unknown'}`")
    lines.append('')
    lines.append('## Storage')
    lines.append('')
    lines.append(f"- Sure repo size: `{data['repo']['size']}`")
    lines.append('- Disk snapshots:')
    for path, out in data['disk'].items():
        first = out.splitlines()[1] if len(out.splitlines()) > 1 else out
        lines.append(f'  - `{path}`: `{first}`')
    lines.append('')
    if data['recommendation']['missing']:
        lines.append('## Missing pieces to install next')
        lines.append('')
        for item in data['recommendation']['missing']:
            lines.append(f'- {item}')
        lines.append('')
    return '\n'.join(lines)


def main():
    args = [arg for arg in sys.argv[1:] if arg != '--json']
    repo = Path(args[0]).resolve() if args else Path.cwd()
    output_json = '--json' in sys.argv[1:]

    data = {
        'host': {
            'platform': platform.platform(),
            'python': platform.python_version(),
            'repo': str(repo),
        },
        'virtualization': detect_virtualization(),
        'tools': {
            'ruby': version_for('ruby', ['-v']),
            'bundler': version_for('bundle', ['-v']),
            'node': version_for('node', ['-v']),
            'npm': version_for('npm', ['-v']),
            'psql': version_for('psql', ['--version']),
            'redis_server': version_for('redis-server', ['--version']),
            'git': version_for('git', ['--version']),
            'curl': version_for('curl', ['--version']),
        },
        'repo': {
            'ruby_required': parse_ruby_version(repo),
            'bundler_required': parse_bundler_version(repo),
            'node_hint': parse_node_hint(repo),
            'size': du(repo),
        },
        'disk': disk_usage(['/','/root','/tmp']),
    }

    strategy, rationale, missing = recommend(
        data['virtualization'],
        data['tools']['ruby'],
        data['tools']['bundler'],
        data['tools']['node'],
        data['tools']['psql'],
        data['tools']['redis_server'],
        data['repo']['ruby_required'],
        data['repo']['bundler_required'],
        data['repo']['node_hint'],
    )
    data['recommendation'] = {
        'strategy': strategy,
        'rationale': rationale,
        'missing': missing,
    }

    if output_json:
        print(json.dumps(data, indent=2))
    else:
        print(markdown_report(data))


if __name__ == '__main__':
    main()
