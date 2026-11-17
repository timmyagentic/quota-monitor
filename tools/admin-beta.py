#!/usr/bin/env python3
"""Owner-triggered Beta release. Every GitHub write preserves branch protection."""
import base64
import hashlib
import html
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request

ADMIN = 'https://admin.timmyagentic.si'
REPO = os.environ.get('GITHUB_REPOSITORY', '')
JOB_ID = os.environ.get('RELEASE_JOB_ID', '')
ROOT = Path.cwd()


def run(*args, capture=False, timeout=3600, env=None):
    result = subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE if capture else None,
                            timeout=timeout, env=env)
    return result.stdout.strip() if capture else ''


def gh(*args):
    return json.loads(run('gh', *args, capture=True))


def ci(action, body=None, method='POST', query=''):
    oidc_url = os.environ['ACTIONS_ID_TOKEN_REQUEST_URL'] + '&audience=' + urllib.parse.quote(ADMIN, safe='')
    token_request = urllib.request.Request(oidc_url, headers={'Authorization': 'Bearer ' + os.environ['ACTIONS_ID_TOKEN_REQUEST_TOKEN']})
    with urllib.request.urlopen(token_request, timeout=60) as response:
        token = json.load(response)['value']
    headers = {'Authorization': 'Bearer ' + token}
    if isinstance(body, Path):
        # urllib needs bytes. The current signed DMG is below the Worker request limit.
        data = body.read_bytes()
        headers['Content-Type'] = 'application/octet-stream'
    else:
        data = json.dumps(body or {}).encode()
        headers['Content-Type'] = 'application/json'
    request = urllib.request.Request(f'{ADMIN}/api/ci/{JOB_ID}/{action}{query}', data=data, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=600) as response:
        return json.load(response)


def progress(text, **fields):
    print(text, flush=True)
    ci('progress', {'text': text, **fields})


def semver(value):
    match = re.fullmatch(r'v?(\d+)\.(\d+)\.(\d+)(?:-beta\.(\d+))?', value)
    if not match:
        return None
    return tuple(int(part) if part else None for part in match.groups())


def next_version(current, tags, private_beta=None):
    parsed = semver(current)
    if not parsed:
        raise ValueError('Current version is invalid')
    base = parsed[:3]
    versions = [version for tag in tags if (version := semver(tag))]
    stable = max((version[:3] for version in versions if version[3] is None), default=(0, 0, 0))
    if base <= stable:
        base = (stable[0], stable[1], stable[2] + 1)
    if REPO.endswith('/cc-connect-next'):
        newer = [version[:3] for version in versions if version[3] is not None]
        base = max([base, *newer])
    if private_beta and (previous := semver(private_beta)):
        base = max(base, previous[:3])
        versions.append(previous)
    seq = max((version[3] or 0 for version in versions if version[:3] == base), default=0) + 1
    if seq >= 9000:
        raise ValueError('Beta sequence exhausted')
    return '.'.join(map(str, base)), seq


def review_resolved(number):
    owner, name = REPO.split('/')
    query = '''query($owner:String!,$name:String!,$number:Int!,$cursor:String){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100,after:$cursor){nodes{isResolved}pageInfo{hasNextPage endCursor}}}}}'''
    cursor = None
    while True:
        args = ['api', 'graphql', '-f', f'query={query}', '-f', f'owner={owner}', '-f', f'name={name}', '-F', f'number={number}']
        if cursor:
            args += ['-f', f'cursor={cursor}']
        threads = gh(*args)['data']['repository']['pullRequest']['reviewThreads']
        if any(not item['isResolved'] for item in threads['nodes']):
            raise RuntimeError(f'PR #{number} has unresolved review threads')
        if not threads['pageInfo']['hasNextPage']:
            return
        cursor = threads['pageInfo']['endCursor']


def check_pr(number, expected_sha):
    pr = gh('pr', 'view', str(number), '--repo', REPO, '--json', 'state,headRefOid,isDraft,baseRefName,mergeCommit')
    if pr['headRefOid'] != expected_sha or pr['isDraft'] or pr['baseRefName'] != 'main':
        raise RuntimeError(f'PR #{number} changed after confirmation')
    if pr['state'] == 'MERGED':
        return False
    if pr['state'] != 'OPEN':
        raise RuntimeError(f'PR #{number} is no longer open')
    review_resolved(number)
    return True


def wait_checks(number, sha):
    if REPO.endswith('/quota-monitor'):
        deadline = time.monotonic() + 2700
        while time.monotonic() < deadline:
            runs = gh('run', 'list', '--repo', REPO, '--workflow', 'tests.yml', '--commit', sha, '--event', 'pull_request', '--json', 'databaseId,status,conclusion', '--limit', '1')
            if runs and runs[0]['status'] == 'completed':
                if runs[0]['conclusion'] != 'success':
                    raise RuntimeError(f'PR #{number} checks failed')
                run('python3', 'tools/verify-cloud-pr.py', str(number), sha)
                return
            time.sleep(20)
        raise TimeoutError(f'PR #{number} checks timed out')
    else:
        checks = gh('pr', 'view', str(number), '--repo', REPO, '--json', 'statusCheckRollup')['statusCheckRollup']
        if checks:
            run('gh', 'pr', 'checks', str(number), '--repo', REPO, '--watch', '--fail-fast', timeout=2700)


def tests():
    # Test subprocesses do not inherit the long-lived publishing credential.
    environment = os.environ.copy()
    environment.pop('GH_TOKEN', None)
    environment.pop('GITHUB_TOKEN', None)
    environment.pop('ACTIONS_ID_TOKEN_REQUEST_TOKEN', None)
    if REPO.endswith('/cc-connect-next'):
        run('pnpm', '--dir', 'web', 'install', '--frozen-lockfile', env=environment)
        run('pnpm', '--dir', 'web', 'build', env=environment)
        run('go', 'test', '-race', './...', env=environment)
        run('go', 'test', '-tags=smoke', './tests/e2e/...', env=environment)
        run('go', 'test', '-tags=regression', './tests/e2e/...', env=environment)
        run('npm', '--prefix', 'npm', 'test', env=environment)
        run('python3', '-m', 'unittest', 'discover', '-s', 'scripts', '-p', 'test_admin_beta.py', env=environment)
        scripts = sorted(str(path) for path in Path('scripts').glob('*.test.js'))
        run('node', '--test', *scripts, env=environment)
    else:
        run('./qa/run-static.sh', env=environment)
        run('swift', 'build', '-c', 'release', env=environment)


def merge_snapshot(job):
    prs = job['prs']
    progress(f'检查 {len(prs)} 个已确认 PR，并验证合并后的完整代码')
    run('git', 'fetch', 'origin', 'main', '--tags')
    run('git', 'checkout', '--detach', 'origin/main')
    pending = []
    for pr in prs:
        if check_pr(pr['number'], pr['sha']):
            wait_checks(pr['number'], pr['sha'])
            run('git', 'fetch', 'origin', f"pull/{pr['number']}/head")
            if run('git', 'rev-parse', 'FETCH_HEAD', capture=True) != pr['sha']:
                raise RuntimeError('PR changed while fetching')
            run('git', 'merge', '--no-edit', '--no-ff', pr['sha'])
            pending.append(pr)
    tree = run('git', 'rev-parse', 'HEAD^{tree}', capture=True)
    tests()
    for pr in pending:
        check_pr(pr['number'], pr['sha'])
        progress(f"合并 PR #{pr['number']}")
        run('gh', 'pr', 'merge', str(pr['number']), '--repo', REPO, '--squash', '--match-head-commit', pr['sha'])
    run('git', 'fetch', 'origin', 'main')
    if run('git', 'rev-parse', 'origin/main^{tree}', capture=True) != tree:
        raise RuntimeError('Main changed concurrently or differs from the tested merged tree')
    run('git', 'checkout', '--detach', 'origin/main')


def promote_notes(version):
    import importlib.util
    spec = importlib.util.spec_from_file_location('release_notes', 'tools/validate-release-notes.py')
    notes = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(notes)
    for filename in ('CHANGELOG.md', 'CHANGELOG.zh-Hans.md'):
        path = Path(filename)
        content = path.read_text()
        unreleased = notes.extract_section(content, 'Unreleased') or ''
        released = notes.extract_section(content, version) or ''
        if not unreleased.strip() and not released.strip():
            raise RuntimeError(f'{filename} has no release notes to publish')
        summaries, details = [], []
        for section in [unreleased, released]:
            if section:
                summary, detail = notes.summary_block(section)
                if summary:
                    summaries.append(summary)
                if detail:
                    details.append(detail)
        combined = '#### Summary\n\n' + '\n'.join(summaries) + '\n\n' + '\n\n'.join(details)
        pattern = r'^##\s+\[Unreleased\][^\n]*\n.*?(?=^##\s+\[|\Z)'
        content = re.sub(pattern, '## [Unreleased]\n\n', content, flags=re.M | re.S)
        pattern = r'^##\s+\[' + re.escape(version) + r'\][^\n]*\n.*?(?=^##\s+\[|\Z)'
        section = f'## [{version}] — {time.strftime("%Y-%m-%d")}\n\n{combined}\n\n'
        if re.search(pattern, content, re.M | re.S):
            content = re.sub(pattern, lambda _: section, content, flags=re.M | re.S)
        else:
            content = content.replace('## [Unreleased]\n\n', '## [Unreleased]\n\n' + section, 1)
        path.write_text(content)


def prepare_version(job):
    current = json.loads(Path('npm/package.json').read_text())['version'] if REPO.endswith('/cc-connect-next') else Path('Resources/VERSION').read_text().strip()
    tags = run('git', 'tag', capture=True).splitlines()
    base, sequence = next_version(current, tags, job.get('privateBetaVersion'))
    version = f'{base}-beta.{sequence}'
    title_lines = [pr['title'] + f" (#{pr['number']})" for pr in job['prs']]
    if not title_lines:
        title_lines = ['包含当前主分支的累计更新。']
    progress(f'准备版本 {version}', version=version)
    branch = f'codex/admin-beta-{JOB_ID}'
    run('git', 'checkout', '-b', branch)
    if REPO.endswith('/cc-connect-next'):
        path = Path('npm/package.json'); package = json.loads(path.read_text()); package['version'] = version
        path.write_text(json.dumps(package, ensure_ascii=False, indent=2) + '\n')
        path = Path('Makefile'); path.write_text(re.sub(r'^VERSION\s*:?=\s*v[^\s#]+', f'VERSION := v{version}', path.read_text(), flags=re.MULTILINE))
        Path(f'changelogs/v{version}.md').write_text(f'# v{version}\n\n' + '\n'.join('- ' + title for title in title_lines) + '\n')
        run('node', 'scripts/check-release-version.js', 'v' + version)
    else:
        Path('Resources/VERSION').write_text(base + '\n')
        promote_notes(base)
        for filename, language in [('CHANGELOG.md', 'en'), ('CHANGELOG.zh-Hans.md', 'zh-Hans')]:
            output = run('python3', 'tools/changelog-to-html.py', '--lang', language, base, filename, capture=True)
            Path(f'ReleaseNotes/{base}.{language}.html').write_text(output + '\n')
        run('python3', 'tools/validate-release-notes.py', base, 'CHANGELOG.md', 'CHANGELOG.zh-Hans.md')
    if run('git', 'status', '--porcelain', capture=True):
        files = ['npm/package.json', 'Makefile', f'changelogs/v{version}.md'] if REPO.endswith('/cc-connect-next') else ['Resources/VERSION', f'ReleaseNotes/{base}.en.html', f'ReleaseNotes/{base}.zh-Hans.html', 'CHANGELOG.md', 'CHANGELOG.zh-Hans.md']
        run('git', 'add', '--', *files)
        run('git', 'commit', '-m', f'Prepare Beta release {version}')
        sha = run('git', 'rev-parse', 'HEAD', capture=True)
        run('git', 'push', 'origin', f'HEAD:refs/heads/{branch}')
        url = run('gh', 'pr', 'create', '--repo', REPO, '--head', branch, '--base', 'main', '--title', f'Prepare Beta release {version}', '--body', f'由发布后台任务 {JOB_ID} 生成。包含已确认的版本元数据与变更记录。', capture=True)
        number = int(url.rstrip('/').split('/')[-1])
        wait_checks(number, sha)
        review_resolved(number)
        run('gh', 'pr', 'merge', str(number), '--repo', REPO, '--squash', '--match-head-commit', sha)
    run('git', 'fetch', 'origin', 'main')
    run('git', 'checkout', '--detach', 'origin/main')
    source = run('git', 'rev-parse', 'HEAD', capture=True)
    progress(f'版本已准备，开始从 {source[:12]} 构建', version=version, sourceSha=source)
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write(f'version={version}\nsource_sha={source}\nbeta_sequence={sequence}\n')
    return version, source


def release_cc(version, source):
    tag = 'v' + version
    # Use the owner-authorized publishing token so the existing tag workflow runs.
    run('git', 'tag', '-a', tag, source, '-m', tag)
    run('git', 'push', 'origin', f'refs/tags/{tag}')
    # The publishing PAT tag push starts the established Release workflow.
    progress(f'{tag} 已提交，等待现有 Release 工作流及公开下载验证')
    deadline = time.monotonic() + 10800
    while time.monotonic() < deadline:
        runs = gh('run', 'list', '--repo', REPO, '--workflow', 'release.yml', '--commit', source, '--event', 'push', '--json', 'databaseId,status,conclusion,headBranch', '--limit', '20')
        release = next((item for item in runs if item['headBranch'] == tag), None)
        if release and release['status'] == 'completed':
            if release['conclusion'] != 'success':
                raise RuntimeError(f'Release workflow failed, run {release["databaseId"]}')
            info = gh('release', 'view', tag, '--repo', REPO, '--json', 'url,isPrerelease,assets')
            if not info['isPrerelease'] or len(info['assets']) < 7:
                raise RuntimeError('Release assets are incomplete')
            with urllib.request.urlopen('https://registry.npmjs.org/cc-connect-next', timeout=60) as response:
                registry = json.load(response)
            if registry['dist-tags'].get('beta') != version:
                raise RuntimeError('npm beta has not reached the expected version')
            progress(f'{tag} 已发布，GitHub 下载与 npm beta 验证通过', status='completed', result={'url': info['url'], 'version': version, 'sourceSha': source})
            return
        time.sleep(30)
    raise TimeoutError('Release workflow timed out; inspect the existing run before retrying')


def publish_quota():
    job = ci('claim')
    version = job['version']; source = job['sourceSha']
    if run('git', 'rev-parse', 'HEAD', capture=True) != source:
        raise RuntimeError('Package source differs from the prepared commit')
    run('./tools/verify-signing-key.sh')
    key = Path(os.environ['RUNNER_TEMP']) / 'sparkle-key'
    key.write_text(os.environ['SPARKLE_PRIVATE_KEY']); key.chmod(0o600)
    run('.build/artifacts/sparkle/Sparkle/bin/generate_keys', '-f', str(key), '--account', 'admin-beta')
    key.unlink()
    artifact = Path(f'dist/QuotaMonitor-{version}.dmg')
    signature = run('.build/artifacts/sparkle/Sparkle/bin/sign_update', '--account', 'admin-beta', str(artifact), capture=True)
    import importlib.util
    spec = importlib.util.spec_from_file_location('private_beta', 'tools/private-beta-release.py')
    publisher = importlib.util.module_from_spec(spec); spec.loader.exec_module(publisher)
    match = publisher.SIGNATURE_PATTERN.search(signature)
    if not match or int(match[2]) != artifact.stat().st_size:
        raise RuntimeError('Invalid Sparkle signature')
    checksum = artifact.with_suffix('.dmg.sha256')
    checksum.write_text(f'{hashlib.sha256(artifact.read_bytes()).hexdigest()}  {artifact.name}\n')
    feed = Path(os.environ['RUNNER_TEMP']) / 'private-beta-appcast.xml'
    base = version.split('-beta.')[0]
    feed.write_text(publisher.appcast_xml(version=version, build=publisher.build_number(base, int(version.split('-beta.')[1])), signature=match[1], length=artifact.stat().st_size, base_url='https://quota-monitor.timmyagentic.com/api/private-beta', artifact_name=artifact.name, minimum_system_version='14.0'))
    files = [(f'artifacts/{artifact.name}', artifact, 'application/x-apple-diskimage'), (f'artifacts/{checksum.name}', checksum, 'text/plain'), (f'notes/{version}.en.html', Path(f'ReleaseNotes/{base}.en.html'), 'text/html'), (f'notes/{version}.zh-Hans.html', Path(f'ReleaseNotes/{base}.zh-Hans.html'), 'text/html'), ('appcast.xml', feed, 'application/xml')]
    manifest = {'version': version, 'sourceSha': source, 'files': [{'name': name, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'contentType': kind} for name, path, kind in files]}
    ci('prepare', manifest)
    progress('上传已公证的安装包、校验文件与更新说明')
    for name, path, _ in files[:-1]:
        ci('upload', path, method='PUT', query='?name=' + urllib.parse.quote(name, safe=''))
    # Publish the feed only after every immutable object is present and verified.
    oidc_url = os.environ['ACTIONS_ID_TOKEN_REQUEST_URL'] + '&audience=' + urllib.parse.quote(ADMIN, safe='')
    req = urllib.request.Request(oidc_url, headers={'Authorization': 'Bearer ' + os.environ['ACTIONS_ID_TOKEN_REQUEST_TOKEN']})
    with urllib.request.urlopen(req, timeout=60) as response:
        token = json.load(response)['value']
    req = urllib.request.Request(f'{ADMIN}/api/ci/{JOB_ID}/publish', data=feed.read_bytes(), headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/xml'}, method='POST')
    with urllib.request.urlopen(req, timeout=60) as response:
        result = json.load(response)
    if not result.get('ok'):
        raise RuntimeError('Feed publication was not confirmed')
    progress(f'{version} 私有 Beta 已发布，安装包摘要与更新源回读通过', status='completed', result={'version': version, 'sourceSha': source})


def main():
    if REPO not in ('timmyagentic/cc-connect-next', 'timmyagentic/quota-monitor') or not re.fullmatch(r'[a-f0-9-]{36}', JOB_ID):
        raise ValueError('Invalid repository or release job')
    if sys.argv[1:] == ['publish-quota']:
        publish_quota(); return
    if sys.argv[1:] == ['verify-only']:
        tests()
        return
    job = ci('claim')
    merge_snapshot(job)
    version, source = prepare_version(job)
    if REPO.endswith('/cc-connect-next'):
        release_cc(version, source)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Only controlled summaries are sent back. Full diagnostics remain in Actions logs.
        print(f'Release stopped: {type(error).__name__}: {error}', file=sys.stderr)
        try:
            progress('流程已停止，请查看 GitHub 日志。已合并的 PR 和已上传的产物会保留，核对后继续处理。', status='needs_attention')
        except Exception:
            pass
        raise
