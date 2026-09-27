#!/usr/bin/env python3
"""Directory APIs against disposable homes, never the caller's XDG files."""
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1] if len(sys.argv) > 1 else os.environ.get('OUROKIT_TEST_BINARY', 'zig-out/bin/ouroctl')).resolve()
app = 'org.example.Paths'
with tempfile.TemporaryDirectory(prefix='ourokit-xdg-') as temporary:
    root = Path(temporary)
    home = root / 'home'
    home.mkdir()
    env = os.environ.copy()
    for key in ('HOME', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME', 'XDG_CONFIG_DIRS', 'XDG_DATA_DIRS', 'XDG_RUNTIME_DIR'):
        env.pop(key, None)
    env.update(HOME=str(home), XDG_RUNTIME_DIR=str(root), DBUS_SESSION_BUS_ADDRESS='unix:path='+str(root / 'no-bus'))
    probe = root / 'probe.lua'
    probe.write_text('''local o=require('ouro')
local p=assert(o.xdg.paths('org.example.Paths'))
local bad,e=o.xdg.paths('../escape'); assert(bad==nil and e.name=='InvalidApplicationId')
bad,e=o.xdg.paths('org..empty'); assert(bad==nil and e.name=='InvalidApplicationId')
local second=o.xdg.paths('org.example.Paths'); second.config_dirs[1]='changed'
assert(p.config_dirs[1]~='changed')
o.stdout.write(o.json.encode(p)..'\\n'); o.exit(0)
''')

    def run(source=probe):
        result = subprocess.run([str(binary), 'run', str(source), '--headless'], env=env,
                                text=True, capture_output=True, timeout=30)
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)

    expected = {'config': str(home / '.config' / app), 'data': str(home / '.local/share' / app),
                'state': str(home / '.local/state' / app), 'cache': str(home / '.cache' / app),
                'runtime': str(root / app), 'config_dirs': [str(home / '.config' / app), '/etc/xdg/'+app],
                'data_dirs': [str(home / '.local/share' / app), '/usr/local/share/'+app, '/usr/share/'+app]}
    assert run() == expected
    assert not list(home.iterdir()), 'lookup must not create directories'
    env.update(XDG_CONFIG_HOME='relative', XDG_STATE_HOME='', XDG_CACHE_HOME='also-relative')
    assert run() == expected, 'relative/empty values must use defaults'
    env.update(XDG_CONFIG_HOME=str(root / 'configuration'), XDG_DATA_HOME=str(root / 'data'),
               XDG_STATE_HOME=str(root / 'state'), XDG_CACHE_HOME=str(root / 'cache'),
               XDG_CONFIG_DIRS='/vendor/config:relative::/system/config', XDG_DATA_DIRS='/vendor/data:/system/data')
    paths = run()
    assert paths['config_dirs'] == [str(root / 'configuration' / app), '/vendor/config/'+app, '/system/config/'+app]
    assert paths['data_dirs'] == [str(root / 'data' / app), '/vendor/data/'+app, '/system/data/'+app]
    assert paths['state'] == str(root / 'state' / app)
    config = root / 'configuration'
    config.mkdir()
    (config / 'user-dirs.dirs').write_text('''# localized and explicitly disabled directories
XDG_DOCUMENTS_DIR="$HOME/Dokumente"
XDG_DOWNLOAD_DIR="/mnt/My Downloads"
XDG_DESKTOP_DIR="$HOME"
XDG_PICTURES_DIR="$HOME/Pictures \\"quoted\\" \\$cash"
XDG_MUSIC_DIR="$(touch /do-not-execute)"
''')
    source = root / 'user.lua'
    source.write_text('''local o=require('ouro')
local out={}
for _,key in ipairs{'documents','download','desktop','pictures','music','videos'} do out[key]=assert(o.xdg.user_dir(key)) end
local bad,e=o.xdg.user_dir('unknown'); assert(bad==nil and e.name=='InvalidUserDirectory')
local p=o.xdg.paths('org.example.Paths')
assert(o.files.mkdir(p.state..'/nested'))
assert(o.files.mkdir(p.state..'/nested'))
assert(o.files.write(p.state..'/nested/value','persisted'))
local fd <close> = assert(o.files.open(p.state..'/nested/value',{writable=true}))
assert(o.files.read(p.state..'/nested/value')=='persisted')
bad,e=o.files.open(p.state..'/nested/value',{writable='yes'}); assert(bad==nil and e.name=='InvalidOptions')
bad,e=o.files.mkdir(p.state..'/bad/../escape'); assert(bad==nil and e.name=='InvalidPath')
bad,e=o.files.mkdir(p.state..'/nested/value/child'); assert(bad==nil and e.name=='NotDirectory')
bad,e=o.files.mkdir(p.state..'/link/child'); assert(bad==nil)
o.stdout.write(o.json.encode(out)..'\\n'); o.exit(0)
''')
    state = root / 'state' / app
    state.mkdir(parents=True)
    (state / 'link').symlink_to(home, target_is_directory=True)
    assert run(source) == {'documents': str(home / 'Dokumente'), 'download': '/mnt/My Downloads',
                           'desktop': str(home), 'pictures': str(home / 'Pictures "quoted" $cash'),
                           'music': str(home), 'videos': str(home)}
    assert not (home / 'child').exists() and not (state / 'bad').exists()
    assert stat.S_IMODE((state / 'nested').stat().st_mode) == 0o700
    assert (state / 'nested/value').read_text() == 'persisted'
    for key in ('HOME','XDG_CONFIG_HOME','XDG_DATA_HOME','XDG_STATE_HOME','XDG_CACHE_HOME','XDG_RUNTIME_DIR'):
        env.pop(key, None)
    missing = run()
    assert all(key not in missing for key in ('config','data','state','cache','runtime'))
print('PASS XDG defaults, overrides, precedence, user directories, explicit mkdir and writable open')
