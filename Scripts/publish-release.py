#!/usr/bin/env python3
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

version = os.environ['BASE_VERSION']
assert re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version)
channel = os.environ['CHANNEL']
assert channel in ('stable', 'beta')
assert os.environ.get('HOMEBREW_TAP_TOKEN'), 'Configure HOMEBREW_TAP_TOKEN before publishing'
if channel == 'beta':
    version += '-beta.' + os.environ['GITHUB_RUN_NUMBER']
repo = os.environ['GITHUB_REPOSITORY']
sha = os.environ['RELEASE_SHA']
tag = 'v' + version
token = 'pipcast' if channel == 'stable' else 'pipcast@beta'
app = 'Pipcast' if channel == 'stable' else 'Pipcast Beta'
tap = 'mSarheed/homebrew-pipcast'
tap_env = dict(os.environ, GH_TOKEN=os.environ['HOMEBREW_TAP_TOKEN'])
def tap_api(path, body=None):
    args = ['gh', 'api', 'repos/' + tap + ('/' + path if path else '')]
    if body is not None:
        args += ['--method', 'PUT', '--input', '-']
    return json.loads(subprocess.check_output(args, input=json.dumps(body).encode() if body else None, env=tap_env))
tap_api('')
arm = Path(f'dist/Pipcast-{version}.dmg')
intel = Path(f'dist/Pipcast-Universal-{version}.dmg')
assert arm.is_file() and intel.is_file()
cask = '''cask "%s" do
  arch arm: "", intel: "-Universal"
  version "%s"
  sha256 arm: "%s",
         intel: "%s"
  url "https://github.com/mSarheed/pipcast/releases/download/v#{version}/Pipcast#{arch}-#{version}.dmg"
  name "%s"
  desc "Native macOS launcher"
  homepage "https://github.com/mSarheed/pipcast"
  auto_updates true
  depends_on macos: :tahoe
  app "%s.app"
end
''' % (token, version, hashlib.sha256(arm.read_bytes()).hexdigest(), hashlib.sha256(intel.read_bytes()).hexdigest(), app, app)
subprocess.run(['ruby', '-c'], input=cask.encode(), check=True)
source = f'dist/Pipcast-{version}-source.tar.gz'
subprocess.run(['git', 'archive', '--format=tar.gz', f'--prefix=Pipcast-{version}/', '--output='+source, sha], check=True)
notes = Path(os.environ['RUNNER_TEMP']) / 'release-notes.md'
notes.write_text(f'{notes.read_text().strip()}\n\n<!-- pipcast:install -->\n\nSigned with Developer ID and notarized by Apple.\n\nInstall: `brew install --cask mSarheed/pipcast/{token}`\n\nSource: https://github.com/{repo}/tree/{sha}\nMatching source archive included under AGPL-3.0-or-later.\n')
args = ['gh', 'release', 'create', tag, *map(str, sorted(Path('dist').glob('*'))), '--repo', repo, '--target', sha, '--title', app+' '+version, '--notes-file', str(notes)]
if channel == 'beta': args += ['--prerelease', '--latest=false']
subprocess.run(args, check=True)
path = 'Casks/' + token + '.rb'
existing = subprocess.run(['gh', 'api', 'repos/'+tap+'/contents/'+path], capture_output=True, env=tap_env)
body = {'message': f'Update {token} to {version}', 'content': base64.b64encode(cask.encode()).decode()}
if existing.returncode == 0:
    body['sha'] = json.loads(existing.stdout)['sha']
elif '404' not in existing.stderr.decode():
    raise RuntimeError(existing.stderr.decode())
tap_api('contents/'+path, body)
print('Published release and updated Homebrew cask')
