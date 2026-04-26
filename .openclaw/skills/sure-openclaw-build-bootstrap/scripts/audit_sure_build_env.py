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
        total, used, free = shutil.disk_usage(p)
        results[p] = {
            'df_h': res['output'],
            'bytes': {
                'total': total,
                'used': used,
                'free': free,
            },
        }
    return results


def gib(bytes_value):
    return round(bytes_value / (1024 ** 3), 2)


def assess_disk(repo_size_text, disk):
    repo_size_bytes = None
    m = re.match(r'^(\d+(?:\.\d+)?)([KMGTP])\s', repo_size_text or '')
    if m:
        scale = {'K': 1024, 'M': 1024 ** 2, 'G': 1024 ** 3, 'T': 1024 ** 4, 'P': 1024 ** 5}
        repo_size_bytes = int(float(m.group(1)) * scale[m.group(2)])

    checks = []
    overall = 'pass'

    thresholds = {
        '/': 2 * 1024 ** 3,
        '/root': 4 * 1024 ** 3,
        '/tmp': 1 * 1024 ** 3,
    }

    for path, minimum in thresholds.items():
        free = disk[path]['bytes']['free']
        status = 'pass' if free >= minimum else 'fail'
        if status == 'fail':
            overall = 'fail'
        checks.append({
            'path': path,
            'status': status,
            'free_gib': gib(free),
            'minimum_gib': gib(minimum),
            'reason': f"Need at least {gib(minimum)} GiB free on {path} before continuing.",
        })

    if repo_size_bytes is not None:
        root_free = disk['/root']['bytes']['free']
        buffer_target = max(2 * repo_size_bytes, 2 * 1024 ** 3)
        status = 'pass' if root_free >= buffer_target else 'warn'
        if status == 'warn' and overall != 'fail':
            overall = 'warn'
        checks.append({
            'path': '/root',
            'status': status,
            'free_gib': gib(root_free),
            'minimum_gib': gib(buffer_target),
            'reason': 'Recommended free space on /root is at least 2x current repo size, with a 2 GiB floor, to leave room for gems, node modules, and caches.',
        })

    return {
        'status': overall,
        'checks': checks,
    }


def du(path):
    res = run(['du', '-sh', str(path)])
    return res['output']


def version_for(cmd, args):
    if not shutil.which(cmd):
        return {'present': False, 'version': None, 'source': None}
    res = run([cmd] + args)
    out = res['output'].splitlines()[0] if res['output'] else ''
    return {'present': True, 'version': out, 'source': shutil.which(cmd)}


def version_for_path(path, args):
    if not Path(path).exists():
        return {'present': False, 'version': None, 'source': None}
    res = run([path] + args)
    out = res['output'].splitlines()[0] if res['output'] else ''
    return {'present': res['ok'], 'version': out if res['ok'] else None, 'source': path}


def detect_ruby_toolchain(ruby_req, bundler_req):
    system_ruby = version_for('ruby', ['-v'])
    system_bundle = version_for('bundle', ['-v'])
    rbenv_ruby = version_for_path('/root/.rbenv/shims/ruby', ['-v'])
    rbenv_bundle = version_for_path('/root/.rbenv/shims/bundle', ['-v'])

    chosen_ruby = system_ruby
    chosen_bundle = system_bundle

    if rbenv_ruby['present'] and ruby_req and ruby_req in (rbenv_ruby['version'] or ''):
        chosen_ruby = rbenv_ruby
    elif not system_ruby['present'] and rbenv_ruby['present']:
        chosen_ruby = rbenv_ruby

    if rbenv_bundle['present'] and bundler_req and bundler_req in (rbenv_bundle['version'] or ''):
        chosen_bundle = rbenv_bundle
    elif not system_bundle['present'] and rbenv_bundle['present']:
        chosen_bundle = rbenv_bundle

    return chosen_ruby, chosen_bundle, {
        'system_ruby': system_ruby,
        'system_bundle': system_bundle,
        'rbenv_ruby': rbenv_ruby,
        'rbenv_bundle': rbenv_bundle,
    }


def recommend(virt, ruby, bundler, node, psql, redis, ruby_req, bundler_req, node_hint, disk_health):
    missing = []
    if not ruby['present'] or (ruby_req and ruby_req not in (ruby['version'] or '')):
        missing.append('Ruby')
    if not bundler['present'] or (bundler_req and bundler_req not in (bundler['version'] or '')):
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

    if disk_health['status'] == 'fail':
        strategy = 'stop-and-free-disk-space'
        rationale.append('Disk-space gate failed. Free space before installing more dependencies or caches.')
    elif disk_health['status'] == 'warn':
        rationale.append('Disk space is above the hard minimum, but below the preferred safety buffer. Continue carefully and monitor growth.')

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
            suffix = f" via `{item['source']}`" if item.get('source') else ''
            lines.append(f"- {name}: `{item['version']}`{suffix}")
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
    for path, details in data['disk'].items():
        out = details['df_h']
        first = out.splitlines()[1] if len(out.splitlines()) > 1 else out
        lines.append(f'  - `{path}`: `{first}`')
    lines.append('')
    lines.append('## Disk-space gate')
    lines.append('')
    lines.append(f"- Overall status: **{data['disk_health']['status']}**")
    for check in data['disk_health']['checks']:
        lines.append(f"- `{check['path']}`: **{check['status']}**, free `{check['free_gib']}` GiB, threshold `{check['minimum_gib']}` GiB")
        lines.append(f"  - {check['reason']}")
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

    ruby_required = parse_ruby_version(repo)
    bundler_required = parse_bundler_version(repo)
    ruby_tool, bundler_tool, ruby_detection = detect_ruby_toolchain(ruby_required, bundler_required)

    data = {
        'host': {
            'platform': platform.platform(),
            'python': platform.python_version(),
            'repo': str(repo),
        },
        'virtualization': detect_virtualization(),
        'tools': {
            'ruby': ruby_tool,
            'bundler': bundler_tool,
            'node': version_for('node', ['-v']),
            'npm': version_for('npm', ['-v']),
            'psql': version_for('psql', ['--version']),
            'redis_server': version_for('redis-server', ['--version']),
            'git': version_for('git', ['--version']),
            'curl': version_for('curl', ['--version']),
        },
        'tool_detection': ruby_detection,
        'repo': {
            'ruby_required': ruby_required,
            'bundler_required': bundler_required,
            'node_hint': parse_node_hint(repo),
            'size': du(repo),
        },
        'disk': disk_usage(['/','/root','/tmp']),
    }
    data['disk_health'] = assess_disk(data['repo']['size'], data['disk'])

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
        data['disk_health'],
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
