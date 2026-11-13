"""GNOME Online Accounts access-token bridge for pinned Caldir 0.14.9.

Refresh credentials remain with GOA. Only short-lived tokens enter a temporary
provider directory for one bounded command; nothing is sent to caldir.org.
"""
from __future__ import annotations
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import tomllib
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

SERVICE='org.gnome.OnlineAccounts'
ACCOUNTS='/org/gnome/OnlineAccounts/Accounts'
MAX_JSON=2*1024*1024


def call(path, interface, method, signature=None, values=None, service=SERVICE):
    try:
        from gi.repository import Gio, GLib
        bus=Gio.bus_get_sync(Gio.BusType.SESSION,None)
        args=GLib.Variant(signature,values) if signature else None
        result=bus.call_sync(service,path,interface,method,args,None,Gio.DBusCallFlags.NONE,30000,None)
        return result.unpack()
    except Exception:
        raise RuntimeError('Google connection is unavailable. Open Online Accounts and reconnect Google.') from None


def manager_running():
    return call('/org/freedesktop/DBus','org.freedesktop.DBus','NameHasOwner','(s)',
                ('org.x.GnomeOnlineAccountsGtk',),service='org.freedesktop.DBus')[0]


def account_property(path,name):
    value=call(path,'org.freedesktop.DBus.Properties','Get','(ss)',(SERVICE+'.Account',name))[0]
    return value.unpack() if hasattr(value,'unpack') else value


def accounts():
    """Enumerate public Account properties without reading OAuth client secrets."""
    xml=call(ACCOUNTS,'org.freedesktop.DBus.Introspectable','Introspect')[0]
    if len(xml)>131072: raise RuntimeError('Too many online accounts')
    result={}
    for node in ET.fromstring(xml).findall('node')[:64]:
        name=node.attrib.get('name','')
        if not re.fullmatch(r'[A-Za-z0-9_]+',name): continue
        path=ACCOUNTS+'/'+name
        if account_property(path,'ProviderType')!='google': continue
        if account_property(path,'CalendarDisabled'): continue
        if account_property(path,'AttentionNeeded'): continue
        identity=account_property(path,'Identity')
        if not isinstance(identity,str) or not re.fullmatch(r'[^\s/\\:]{1,200}@[^\s/\\:]{1,200}',identity): continue
        result[identity]=path
    return result


def access_token(path):
    token,seconds=call(path,SERVICE+'.OAuth2Based','GetAccessToken')
    if not isinstance(token,str) or not token or len(token)>16384 or any(ord(c)<32 for c in token):
        raise RuntimeError('GOA returned an invalid access token')
    if not isinstance(seconds,int) or seconds<180:
        raise RuntimeError('Google sign-in needs renewal in Online Accounts')
    return token,min(seconds,86400)


def write_private(path,text):
    path.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
    if path.is_symlink(): raise RuntimeError('Refusing a symbolic credential path')
    with tempfile.NamedTemporaryFile('w',dir=path.parent,delete=False) as output:
        output.write(text)
        temporary=Path(output.name)
    temporary.chmod(0o600)
    temporary.replace(path)


def google_calendars(token):
    rows=[]
    page=None
    for _ in range(5):
        query={'maxResults':'250','minAccessRole':'reader','showHidden':'false'}
        if page: query['pageToken']=page
        url='https://www.googleapis.com/calendar/v3/users/me/calendarList?'+urllib.parse.urlencode(query)
        request=urllib.request.Request(url,headers={'Authorization':'Bearer '+token,'Accept':'application/json'})
        # Google API does not require redirects. Never forward bearer credentials.
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self,*args,**kwargs): return None
        with urllib.request.build_opener(NoRedirect()).open(request,timeout=25) as response:
            body=response.read(MAX_JSON+1)
        if len(body)>MAX_JSON: raise RuntimeError('Google calendar list exceeds the size limit')
        value=json.loads(body)
        items=value.get('items',[])
        if not isinstance(items,list): raise RuntimeError('Invalid Google calendar list')
        rows.extend(items)
        if len(rows)>1000: raise RuntimeError('Too many Google calendars')
        page=value.get('nextPageToken')
        if not page: return rows
    raise RuntimeError('Google calendar list exceeds the page limit')


def connect_primary(config,data,identity):
    paths=accounts()
    if identity not in paths: raise RuntimeError('The selected Google account is not connected')
    token,_=access_token(paths[identity])
    rows=google_calendars(token)
    choices=[r for r in rows if r.get('primary') and r.get('accessRole') in ('owner','writer')]
    if len(choices)!=1: raise RuntimeError('A writable primary Google calendar was not found')
    row=choices[0]
    remote_id=row.get('id')
    if not isinstance(remote_id,str) or not 0<len(remote_id)<1024: raise RuntimeError('Invalid calendar identifier')
    slug='google-'+hashlib.sha256((identity+'\0'+remote_id).encode()).hexdigest()[:20]
    profile=config/'caldir/config.toml'
    current=tomllib.loads(profile.read_text())
    mapping=config/'goa.json'
    if mapping.exists():
        old=json.loads(mapping.read_text())
        if old.get('identity')!=identity: raise RuntimeError('An existing calendar cannot be rebound to another Google account')
        if old.get('remote_id',remote_id)!=remote_id or old.get('calendar',slug)!=slug:
            raise RuntimeError('An existing calendar cannot be rebound to a different remote calendar')
    calendar=data/'calendars'/slug
    calendar.mkdir(parents=True,exist_ok=True,mode=0o700)
    name=str(row.get('summary','Google Calendar'))[:300]
    color=row.get('backgroundColor','#4285f4')
    if not re.fullmatch(r'#[0-9A-Fa-f]{6}',str(color)): color='#4285f4'
    text='name = '+json.dumps(name,ensure_ascii=False)+'\ncolor = '+json.dumps(color)+'\nread_only = false\n\n[remote]\nprovider = "google"\ngoogle_account = '+json.dumps(identity)+'\ngoogle_calendar_id = '+json.dumps(remote_id)+'\n'
    write_private(calendar/'.caldir/config.toml',text)
    # Google-default reminder offsets are metadata, not OAuth credentials.
    defaults=[r.get('minutes') for r in row.get('defaultReminders',[]) if r.get('method')=='popup' and isinstance(r.get('minutes'),int) and 0<=r['minutes']<=40320][:5]
    write_private(calendar/'.caldir/google-reminders.json',json.dumps(defaults)+'\n')
    write_private(mapping,json.dumps({'schema':1,'identity':identity,'object_path':paths[identity],'calendar':slug,'remote_id':remote_id},ensure_ascii=False)+'\n')
    content=profile.read_text()
    replacement='default_calendar = '+json.dumps(slug)
    if re.search(r'(?m)^default_calendar\s*=',content):
        content=re.sub(r'(?m)^default_calendar\s*=.*$',replacement,content)
    else: content+='\n'+replacement+'\n'
    write_private(profile,content)
    return slug


@contextmanager
def token_environment(config,data,environment):
    """Keep credentials only for this command, with at least 180 seconds left."""
    wanted=set()
    for path in (data/'calendars').glob('*/.caldir/config.toml'):
        value=tomllib.loads(path.read_text()).get('remote',{})
        if value.get('provider')=='google': wanted.add(value.get('google_account'))
    if not wanted:
        yield environment
        return
    binding=json.loads((config/'goa.json').read_text())
    if wanted!={binding.get('identity')}:
        raise RuntimeError('Google account does not match the private calendar binding')
    for path in (data/'calendars').glob('*/.caldir/config.toml'):
        remote=tomllib.loads(path.read_text()).get('remote',{})
        if remote.get('provider')=='google' and (path.parent.parent.name!=binding.get('calendar') or remote.get('google_calendar_id')!=binding.get('remote_id')):
            raise RuntimeError('Google calendar does not match the private calendar binding')
    available=accounts()
    runtime=Path(os.environ.get('XDG_RUNTIME_DIR',''))
    if not runtime.is_absolute() or not runtime.is_dir() or runtime.stat().st_uid!=os.getuid():
        raise RuntimeError('A private user runtime directory is required')
    with tempfile.TemporaryDirectory(prefix='omarchy-calendar-goa-',dir=runtime) as folder:
        store=Path(folder)
        store.chmod(0o700)
        write_private(store/'app_config.toml','client_id = ""\nclient_secret = ""\n')
        for identity in wanted:
            if identity not in available: raise RuntimeError('Reconnect Google in Online Accounts')
            token,seconds=access_token(available[identity])
            expiry=datetime.now(timezone.utc)+timedelta(seconds=seconds)
            name=re.sub(r'[/\\:]','_',identity)
            payload='access_token = '+json.dumps(token)+'\nrefresh_token = ""\nexpires_at = '+json.dumps(expiry.isoformat().replace('+00:00','Z'))+'\nauth_mode = "local"\n'
            write_private(store/'session'/(name+'.toml'),payload)
        env=environment.copy()
        env['CALDIR_PROVIDER_STORAGE_DIR']=str(store)
        yield env
