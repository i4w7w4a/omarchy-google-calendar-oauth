import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
ID='re_pick.google-calendar-clock'
loader=importlib.machinery.SourceFileLoader('calendar_browser',str(ROOT/'scripts/calendar-online-accounts'))
spec=importlib.util.spec_from_loader(loader.name,loader)
browser=importlib.util.module_from_spec(spec);loader.exec_module(browser)

class PublicInstallTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='calendar-public-install-')
        self.addCleanup(self.temp.cleanup)
        self.base=Path(self.temp.name)
        self.fake_home=self.base/'user';self.fake_home.mkdir()
        self.state=self.base/'state';self.state.mkdir()
        self.bin=self.base/'bin';self.bin.mkdir()
        tool=self.bin/'omarchy';tool.write_text('#!/usr/bin/python3\nraise SystemExit(0)\n');tool.chmod(0o755)
        self.config=self.fake_home/'.config/omarchy';self.config.mkdir(parents=True)
        self.initial={'bar':{'layout':{'center':[{'id':ID,'calendarAutoPush':False,'calendarPanelPosition':'screen-center'}],'right':['omarchy.audio']}},'version':1}
        (self.config/'shell.json').write_text(json.dumps(self.initial))
        self.destination=self.config/'plugins'/ID
        self.destination.mkdir(parents=True)
        self.source=self.base/'source';self.source.mkdir()
        for root in [self.source,self.destination]:
            shutil.copy2(ROOT/'install-local',root/'install-local')
            (root/'manifest.json').write_text('{}')
            (root/'setup').write_text('#!/usr/bin/python3\nraise SystemExit(0)\n');(root/'setup').chmod(0o755)

    def run_install(self,inplace):
        if not shutil.which('bwrap'):self.skipTest('bubblewrap is required for safe installer test')
        command=str(Path.home()/'.config/omarchy/plugins'/ID/'install-local') if inplace else str(self.source/'install-local')
        env={**os.environ,'PATH':str(self.bin)+':/usr/bin:/bin','XDG_STATE_HOME':str(self.state)}
        return subprocess.run(['bwrap','--die-with-parent','--unshare-net','--ro-bind','/','/','--dev','/dev','--bind',str(self.base),str(self.base),'--bind',str(self.fake_home),str(Path.home()),'--',command],env=env,capture_output=True,text=True,timeout=10)

    def test_in_place_keeps_git_and_user_preferences(self):
        (self.destination/'.git').mkdir();(self.destination/'.git/config').write_text('sentinel')
        result=self.run_install(True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((self.destination/'.git/config').read_text(),'sentinel')
        value=json.loads((self.config/'shell.json').read_text())
        self.assertFalse(value['bar']['layout']['center'][0]['calendarAutoPush'])
        self.assertEqual(value['bar']['layout']['center'][0]['calendarPanelPosition'],'screen-center')
        self.assertEqual(value['bar']['layout']['right'],['omarchy.audio'])

    def test_external_install_refuses_existing_git_checkout(self):
        (self.destination/'.git').mkdir();(self.destination/'.git/config').write_text('sentinel')
        before=(self.config/'shell.json').read_bytes()
        result=self.run_install(False)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual((self.config/'shell.json').read_bytes(),before)
        self.assertEqual((self.destination/'.git/config').read_text(),'sentinel')

    def test_string_clock_entry_is_replaced(self):
        self.initial['bar']['layout']['center']=['omarchy.clock']
        (self.config/'shell.json').write_text(json.dumps(self.initial))
        result=self.run_install(True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads((self.config/'shell.json').read_text())['bar']['layout']['center'][0]['id'],ID)

    def test_no_browser_override_uses_system_default(self):
        self.assertIsNone(browser.browser_choice(self.fake_home/'.config'))

    def test_browser_override_is_argv_not_shell(self):
        folder=self.fake_home/'.config/omarchy-calendar';folder.mkdir()
        value={'executable':'/usr/bin/true','arguments':['--profile-directory=Default','literal;$(no-shell)']}
        (folder/'browser.json').write_text(json.dumps(value))
        self.assertEqual(browser.browser_choice(self.fake_home/'.config'),value)
        value['arguments']=['invalid\nargument'];(folder/'browser.json').write_text(json.dumps(value))
        with self.assertRaises(RuntimeError):browser.browser_choice(self.fake_home/'.config')

if __name__=='__main__':unittest.main()
