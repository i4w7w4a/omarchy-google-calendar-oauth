import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader('calendar_setup', str(ROOT / 'setup'))
spec = importlib.util.spec_from_loader(loader.name, loader)
setup = importlib.util.module_from_spec(spec)
loader.exec_module(setup)


class Response(io.BytesIO):
    url = 'https://release-assets.githubusercontent.com/test'


class SetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / 'config/omarchy-calendar'
        self.data = self.root / 'data/omarchy-calendar'
        self.state = self.root / 'state'
        setup.prepare_profile(self.config,self.data)

    def archive(self, symlink=False):
        data = io.BytesIO()
        with tarfile.open(fileobj=data,mode='w:gz') as archive:
            for name in setup.BIN_NAMES:
                info = tarfile.TarInfo('./'+name)
                payload = b'#!/bin/sh\nexit 0\n'
                if symlink and name=='caldir':
                    info.type = tarfile.SYMTYPE
                    info.linkname = '/tmp/should-not-follow'
                    archive.addfile(info)
                else:
                    info.size=len(payload)
                    archive.addfile(info,io.BytesIO(payload))
        return data.getvalue()

    def spec_for(self, payload):
        specdir = self.root/'source'
        specdir.mkdir(exist_ok=True)
        spec={'version':'test','commit':'0'*40,'assets':{'x86_64':{
            'url':'https://github.com/test/test/releases/download/v1/test.tar.gz',
            'sha256':hashlib.sha256(payload).hexdigest(),
            'binaries':{n:hashlib.sha256(b'#!/bin/sh\nexit 0\n').hexdigest() for n in setup.BIN_NAMES}}}}
        (specdir/'runtime.json').write_text(json.dumps(spec))
        return specdir

    def test_rejects_profile_outside_private_directory(self):
        (self.config/'caldir/config.toml').write_text('calendar_dir = "/tmp/other"\n')
        with self.assertRaises(RuntimeError): setup.prepare_profile(self.config,self.data)

    def test_rejects_config_symlink(self):
        config=self.config/'caldir/config.toml'
        config.unlink()
        config.symlink_to(self.root/'external')
        with self.assertRaises(RuntimeError): setup.prepare_profile(self.config,self.data)

    def test_archive_symlink_is_never_extracted(self):
        payload=self.archive(symlink=True)
        with patch.object(setup,'ROOT',self.spec_for(payload)),patch.object(setup.platform,'machine',return_value='x86_64'),patch.object(setup.urllib.request,'urlopen',return_value=Response(payload)):
            with self.assertRaises(RuntimeError): setup.install_runtime(self.data,self.state)
        self.assertFalse((self.data/'bin').exists())

    def test_digest_mismatch_never_installs(self):
        payload=self.archive()
        with patch.object(setup,'ROOT',self.spec_for(payload)),patch.object(setup.platform,'machine',return_value='x86_64'),patch.object(setup.urllib.request,'urlopen',return_value=Response(b'corrupt')):
            with self.assertRaises(RuntimeError): setup.install_runtime(self.data,self.state)
        self.assertFalse((self.data/'bin').exists())

    def test_existing_runtime_must_match_pinned_member_digests(self):
        payload=self.archive()
        with patch.object(setup,'ROOT',self.spec_for(payload)),patch.object(setup.platform,'machine',return_value='x86_64'),patch.object(setup.urllib.request,'urlopen',side_effect=lambda *a,**k:Response(payload)) as fetch:
            setup.install_runtime(self.data,self.state)
            binary=self.data/'bin/caldir'
            binary.write_bytes(b'altered')
            metadata=self.data/'bin/BUILD-INFO.json'
            info=json.loads(metadata.read_text())
            info['binaries']['caldir']=hashlib.sha256(b'altered').hexdigest()
            metadata.write_text(json.dumps(info))
            setup.install_runtime(self.data,self.state)
            self.assertEqual(fetch.call_count,2)
            self.assertEqual(binary.read_bytes(),b'#!/bin/sh\nexit 0\n')

    def test_wrapper_rejects_update_with_global_prefix_and_force(self):
        binaries=self.data/'bin'
        binaries.mkdir()
        for name in setup.BIN_NAMES:
            path=binaries/name
            path.write_text('#!/bin/sh\nprintf "EXECUTED\\n"\n')
            path.chmod(0o700)
        env=dict(os.environ,XDG_CONFIG_HOME=str(self.config.parent),XDG_DATA_HOME=str(self.data.parent))
        wrapper=str(ROOT/'scripts/calendar-caldir')
        for args in (['update'],['--timeout','1s','update'],['push','--force'],['connect','google'],['sync']):
            result=subprocess.run([wrapper,*args],env=env,capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0,args)
            self.assertNotIn('EXECUTED',result.stdout,args)
        result=subprocess.run([wrapper,'config','--json'],env=env,capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('EXECUTED',result.stdout)


if __name__=='__main__': unittest.main()
