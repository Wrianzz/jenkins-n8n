"""Run the real deploy script with fake n8n API and Docker/Kubernetes commands.

Requires bash, jq, and Python 3. No production services are contacted.
Run: python3 -m unittest discover -s tests -v
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/deploy-from-git.sh'
MOCK = r'''#!/usr/bin/env python3
import json, os, pathlib, shlex, sys
root = pathlib.Path(os.environ['MOCK_ROOT'])
state = json.loads((root / 'state.json').read_text())
command = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
scenario = os.environ.get('SCENARIO', '')
def event(value):
    with (root / 'events.jsonl').open('a') as f:
        f.write(json.dumps(value) + '\n')
def save():
    (root / 'state.json').write_text(json.dumps(state))
def stage(path):
    data = json.loads(pathlib.Path(path).read_text())
    assert not data['active'] and data['activeVersionId'] is None
    assert 'versionId' not in data and 'activeVersion' not in data
    state['staged'] = data
    save()
def do_import():
    wf = state['staged']
    wid = wf['id']
    event(['import', wid])
    if scenario == 'import_failure': sys.exit(1)
    if scenario == 'import_skipped': return
    previous = state['workflows'].get(wid)
    assert previous is None or not previous['active'], 'import before unpublish'
    wf['versionId'] = 'prod-new-' + wid
    state['workflows'][wid] = wf
    save()
if command == 'psql':
    print('project-test')
elif command == 'scp':
    if scenario == 'copy_failure': sys.exit(1)
    stage(args[-2])
elif command == 'ssh':
    inner = shlex.split(args[-1])
    if 'import:workflow' in inner: do_import()
    elif 'publish:workflow' in inner: raise AssertionError('CLI publish fallback')
elif command == 'kubectl':
    if 'get' in args:
        print('n8n-test-pod')
    elif 'cp' in args:
        if scenario == 'copy_failure': sys.exit(1)
        stage(args[args.index('cp') + 1])
    elif 'import:workflow' in args: do_import()
    elif 'publish:workflow' in args: raise AssertionError('CLI publish fallback')
elif command == 'curl':
    method = args[args.index('--request') + 1]
    output = pathlib.Path(args[args.index('--output') + 1])
    parts = args[-1].split('/workflows/')[-1].split('/')
    wid, action = parts[0], parts[1] if len(parts) > 1 else ''
    event([method, wid, action])
    code = 200
    wf = state['workflows'].get(wid)
    if scenario == 'transport_failure': sys.exit(28)
    if scenario == 'lookup_forbidden' and method == 'GET':
        code = 403
    elif method == 'GET':
        if wf is None: code = 404
    elif action == 'deactivate':
        if scenario == 'unpublish_failure': code = 500
        elif scenario != 'unpublish_noop':
            wf['active'] = False
            wf['activeVersionId'] = None
    elif action == 'activate':
        payload = json.loads(args[args.index('--data') + 1])
        assert payload['versionId'] == wf['versionId'] == 'prod-new-' + wid
        if scenario == 'publish_failure': code = 409
        else:
            wf['active'] = True
            wf['activeVersionId'] = ('prod-old' if scenario == 'stale_publish' else payload['versionId'])
    save()
    if scenario == 'invalid_json': output.write_text('<html>proxy response</html>')
    else: output.write_text(json.dumps(wf if code == 200 else {'message': 'mock error'}))
    print(code, end='')
else:
    raise AssertionError(command)
'''


class DeployPublicationTests(unittest.TestCase):
    def run_deploy(self, runtime='docker', scenario='', existing=True, sub=False, array=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            shutil.copy(SCRIPT, root / 'scripts/deploy-from-git.sh')
            (root / 'workflows').mkdir()
            ids = ['mainworkflow01', 'subworkflow01'] if sub else ['mainworkflow01']
            workflows = {}
            for wid in ids:
                data = dict(id=wid, name=wid, nodes=[], connections={}, settings={},
                            active=True, versionId='dev-version', activeVersionId='dev-old',
                            activeVersion={'versionId': 'dev-old'})
                (root / f'workflows/{wid}.json').write_text(json.dumps([data] if array else data))
                if existing:
                    workflows[wid] = dict(data, versionId='prod-old', activeVersionId='prod-old')
                    if scenario == 'inactive':
                        workflows[wid].update(active=False, activeVersionId=None)
            if scenario == 'wrong_id':
                data['id'] = 'differentworkflow'
                (root / 'workflows/mainworkflow01.json').write_text(json.dumps(data))
            (root / 'state.json').write_text(json.dumps({'workflows': workflows}))
            (root / 'events.jsonl').touch()
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            mock = bin_dir / 'mock'
            mock.write_text(MOCK)
            mock.chmod(0o755)
            for command in ('curl', 'ssh', 'scp', 'kubectl', 'psql'):
                (bin_dir / command).symlink_to(mock)
            env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'],
                       MOCK_ROOT=str(root), SCENARIO=scenario,
                       PROD_SSH_HOST='test', PROD_PG_HOST='test', PROD_DEPLOY_TARGET=runtime,
                       PROD_N8N_API_BASE_URL='https://mock.invalid/api/v1/', PROD_N8N_API_KEY='test-key',
                       PROD_K8S_NAMESPACE='test', PROD_K8S_CONTAINER='n8n')
            result = subprocess.run(
                ['bash', str(root / 'scripts/deploy-from-git.sh'), ids[0], ids[1] if sub else ''],
                env=env, capture_output=True, text=True, timeout=20)
            events = [json.loads(line) for line in (root / 'events.jsonl').read_text().splitlines()]
            state = json.loads((root / 'state.json').read_text())
            return result, events, state

    def test_existing_new_and_inactive_workflows_on_both_runtimes(self):
        for runtime in ('docker', 'kubernetes', 'kubectl'):
            for existing, scenario, array in ((True, '', False), (False, '', True), (True, 'inactive', True)):
                with self.subTest(runtime=runtime, existing=existing, scenario=scenario):
                    result, events, state = self.run_deploy(runtime, scenario, existing, sub=True, array=array)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    expected = []
                    for wid in ('subworkflow01', 'mainworkflow01'):
                        expected.append(['GET', wid, ''])
                        if existing:
                            expected.extend([['POST', wid, 'deactivate'], ['GET', wid, '']])
                        expected.extend([['import', wid], ['GET', wid, ''],
                                         ['POST', wid, 'activate'], ['GET', wid, '']])
                        wf = state['workflows'][wid]
                        self.assertEqual(wf['activeVersionId'], 'prod-new-' + wid)
                    self.assertEqual(events, expected)

    def test_failures_abort_without_cli_publish_fallback(self):
        for runtime in ('docker', 'kubernetes'):
            for scenario in ('lookup_forbidden', 'transport_failure', 'invalid_json',
                             'unpublish_failure', 'unpublish_noop', 'import_failure',
                             'import_skipped', 'publish_failure', 'stale_publish', 'copy_failure', 'wrong_id'):
                with self.subTest(runtime=runtime, scenario=scenario):
                    result, events, _ = self.run_deploy(runtime, scenario)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertNotIn('[OK] Workflow', result.stdout)
                    if scenario not in ('import_failure', 'import_skipped', 'publish_failure', 'stale_publish'):
                        self.assertFalse(any(e[0] == 'import' for e in events), events)
                    if scenario not in ('publish_failure', 'stale_publish'):
                        self.assertFalse(any(e[-1] == 'activate' for e in events), events)


if __name__ == '__main__':
    unittest.main()
