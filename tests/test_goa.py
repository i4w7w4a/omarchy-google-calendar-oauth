import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import tomllib
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
import calendar_goa as goa


class GoaTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.config=self.root/'config'
        self.data=self.root/'data'
        self.runtime=self.root/'runtime'
        self.runtime.mkdir(mode=0o700)
        (self.config/'caldir').mkdir(parents=True)
        (self.config/'caldir/config.toml').write_text('calendar_dir = '+json.dumps(str(self.data/'calendars'))+'\n')

    def test_account_discovery_never_requests_oauth_properties(self):
        def invoke(path,interface,method,signature=None,values=None):
            if method=='Introspect':return ('<node><node name="account_1"/><node name="../escape"/></node>',)
            self.assertEqual(interface,'org.freedesktop.DBus.Properties')
            self.assertEqual(method,'Get')
            self.assertEqual(values[0],goa.SERVICE+'.Account')
            return ({'ProviderType':'google','CalendarDisabled':False,'AttentionNeeded':False,'Identity':'demo@example.com'}[values[1]],)
        with patch.object(goa,'call',side_effect=invoke):
            self.assertEqual(goa.accounts(),{'demo@example.com':goa.ACCOUNTS+'/account_1'})

    def test_expired_and_unknown_lifetime_refused(self):
        for seconds in [0,60,179]:
            with patch.object(goa,'call',return_value=('fixture-token',seconds)):
                with self.assertRaises(RuntimeError):goa.access_token('/account')

    def bootstrap(self):
        with patch.object(goa,'accounts',return_value={'demo@example.com':'/account'}),patch.object(goa,'access_token',return_value=('fixture-token',3600)),patch.object(goa,'google_calendars',return_value=[{'id':'demo@example.com','primary':True,'accessRole':'owner','summary':'<img src="https://invalid.invalid">\nCalendar','backgroundColor':'#336699','defaultReminders':[{'method':'popup','minutes':10}]}]):
            return goa.connect_primary(self.config,self.data,'demo@example.com')

    def test_bootstrap_keeps_text_and_binds_primary(self):
        slug=self.bootstrap()
        path=self.data/'calendars'/slug/'.caldir/config.toml'
        value=tomllib.loads(path.read_text())
        self.assertEqual(value['remote']['google_account'],'demo@example.com')
        self.assertIn('<img',value['name'])
        self.assertEqual(value['read_only'],False)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode),0o600)
        self.assertEqual(tomllib.loads((self.config/'caldir/config.toml').read_text())['default_calendar'],slug)
        self.assertEqual(json.loads((path.parent/'google-reminders.json').read_text()),[10])

    def test_ephemeral_access_token_has_no_refresh_secret_and_is_removed(self):
        self.bootstrap()
        with patch.dict(os.environ,{'XDG_RUNTIME_DIR':str(self.runtime)}),patch.object(goa,'accounts',return_value={'demo@example.com':'/account'}),patch.object(goa,'access_token',return_value=('fixture-token',3600)):
            with goa.token_environment(self.config,self.data,{'PATH':'fixture'}) as env:
                folder=Path(env['CALDIR_PROVIDER_STORAGE_DIR'])
                data=tomllib.loads((folder/'session/demo@example.com.toml').read_text())
                self.assertEqual(data['access_token'],'fixture-token')
                self.assertEqual(data['refresh_token'],'')
                self.assertEqual(data['auth_mode'],'local')
                self.assertEqual(tomllib.loads((folder/'app_config.toml').read_text()),{'client_id':'','client_secret':''})
                self.assertEqual(stat.S_IMODE(folder.stat().st_mode),0o700)
                self.assertEqual(stat.S_IMODE((folder/'session/demo@example.com.toml').stat().st_mode),0o600)
            self.assertFalse(folder.exists())
        self.assertFalse((self.config/'caldir/providers/google/session').exists())

    def test_removed_account_does_not_use_stale_token(self):
        self.bootstrap()
        with patch.dict(os.environ,{'XDG_RUNTIME_DIR':str(self.runtime)}),patch.object(goa,'accounts',return_value={}):
            with self.assertRaises(RuntimeError):
                with goa.token_environment(self.config,self.data,{}):pass
        self.assertEqual(list(self.runtime.iterdir()),[])

    def test_existing_calendar_cannot_switch_account(self):
        self.bootstrap()
        with patch.object(goa,'accounts',return_value={'other@example.com':'/other'}),patch.object(goa,'access_token',return_value=('fixture-token',3600)),patch.object(goa,'google_calendars',return_value=[{'id':'other@example.com','primary':True,'accessRole':'owner'}]):
            with self.assertRaises(RuntimeError):goa.connect_primary(self.config,self.data,'other@example.com')


if __name__=='__main__':unittest.main()
