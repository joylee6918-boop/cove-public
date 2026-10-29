"""Owner-authenticated Cove bridge to the private, single-world travel service.

The model receives four thread-bound tools, never the service credential or an
accept-invitation tool. Phone replies carry the scene seen at compose time.
"""
import hashlib
import json
import os
import re
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, build_opener, ProxyHandler, HTTPRedirectHandler

from storage import APIError, encode, now

_ID = re.compile(r'^[A-Za-z0-9_.:-]{1,600}$')
TRAVEL_GUIDANCE = (
    '旅行工具为 travel_journey / travel_move / travel_sense / travel_memory。'
    '默认双人 together，start 只发邀请，不能替用户接受；邀请后正常说话并等她。'
    '双人每一幕必须等对应 sceneID 的真实用户回应；同一回合最多推进一幕。'
    '暂停和结束不受等待锁限制，不通过别的工具或脚本绕过。'
    '不要替用户编造未表达的台词、感受或重大动作。'
    '地点与行走属于虚拟旅行；按来源区分实时天气、离线估算和叙事素材。'
    '没有旅行时普通聊天不需要调用旅行工具；失败不要声称已出发。'
    '旅行拍照须使用真实image_generation能力，生成影像不是当地实拍。原生成功图片会附加到当前回复，'
    '并尝试收入开始生图时的已落地场景；可用travel_memory list核对照片列表，确认后才称已入册，失败不编造照片。'
    '独立发送的生成图片可用travel_memory(action=photo,journeyID,sceneID,attachmentID,caption)收入。'
)


def schema(name, description, props, required=('action',)):
    return {'name': name, 'description': description,
            'inputSchema': {'type': 'object', 'properties': props,
                            'required': list(required), 'additionalProperties': False}}


def enum(*values):
    return {'type': 'string', 'enum': list(values)}


TRAVEL_TOOLS = [
    schema('travel_journey', '旅行状态/档案、出发邀请、暂停、继续、结束。默认 together 仅发邀请，必须由用户在手机接受。不能代接受。', {
        'action': enum('status','list','start','pause','continue','end'),
        'destination': {'type':'string','maxLength':160}, 'mode':enum('solo','together')}),
    schema('travel_move', '推进一幕行走或等待。双人模式会锁定，等用户对应场景回应后才能再走。', {
        'action':enum('walk','wait'), 'direction':{'type':'string','maxLength':40},
        'distance_km':{'type':'number','minimum':0.01,'maximum':5},
        'hours':{'type':'number','minimum':0.25,'maximum':12}}),
    schema('travel_sense', '把一幕注意力给方向、周围、地方知识或电台。双人模式同样一幕一回应。', {
        'action':enum('look','around','ask','radio'),
        'direction':{'type':'string','maxLength':40}, 'topic':{'type':'string','maxLength':200}}),
    schema('travel_memory', '查看旅行痕迹、标记地点、写明信片。photo将当前回复已交付的AI生成图片attachmentID收入指定journeyID/sceneID，caption为图注；先真实生成和发送附件，不能编造图片或引用表情包。收照片不推进旅行。', {
        'action':enum('list','mark','postcard','photo'),
        'journeyID':{'type':'string','maxLength':160}, 'sceneID':{'type':'string','maxLength':160},
        'attachmentID':{'type':'string','maxLength':160}, 'caption':{'type':'string','maxLength':500}, 'name':{'type':'string','maxLength':120},
        'note':{'type':'string','maxLength':500}, 'text':{'type':'string','maxLength':1000}}),
]
TRAVEL_NAMES = {t['name'] for t in TRAVEL_TOOLS}


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise APIError(503, '旅行服务地址异常，未跟随跳转')


def bounded_id(value):
    if not isinstance(value, str) or not _ID.fullmatch(value):
        raise APIError(400, '旅行标识无效')
    return value


class TravelBridge:
    def __init__(self, store, token_path=None, base=None):
        self.store = store
        from travel_album import TravelAlbum
        self.album = TravelAlbum(store)
        self.token_path = token_path or os.getenv('COVE_TRAVEL_TOKEN_FILE', '')
        self.base = base or 'http://127.0.0.1:18797'
        # No proxies, redirects, model URLs or user-controlled destinations.
        if not re.fullmatch(r'http://127\.0\.0\.1:[0-9]{1,5}', self.base):
            raise ValueError('Travel bridge must use a loopback address')
        with store.lock, store.db:
            store.db.execute('CREATE TABLE IF NOT EXISTS travel_snapshots(conversation TEXT PRIMARY KEY, revision INTEGER NOT NULL, body TEXT NOT NULL)')

    @property
    def enabled(self):
        return bool(self.token_path)

    def _request(self, path, body=None, timeout=95):
        if not self.enabled:
            raise APIError(503, '旅行服务尚未启用')
        try:
            token = Path(self.token_path).read_text().strip()
            if len(token) < 32:
                raise ValueError()
        except (OSError, ValueError):
            raise APIError(503, '旅行服务凭据不可用') from None
        req = Request(self.base+path, data=encode(body).encode() if body is not None else None,
                      headers={'Content-Type':'application/json', 'Authorization':'Bearer '+token})
        try:
            with build_opener(ProxyHandler({}), NoRedirect()).open(req, timeout=timeout) as response:
                payload = response.read(2_000_001)
            if len(payload) > 2_000_000:
                raise ValueError()
            result = json.loads(payload)
            if not isinstance(result, dict):
                raise ValueError()
            if body is not None and not isinstance(result.get('snapshot'), dict):
                raise ValueError()
            return result
        except HTTPError as error:
            try:
                result = json.loads(error.read(2_000_000))
                if not isinstance(result, dict):
                    raise ValueError()
                if isinstance(result.get('snapshot'),dict) and body is not None:
                    self._record(body['conversationID'], result['snapshot'])
                reason = result.get('error')
                reason = reason.get('message') if isinstance(reason,dict) else reason
                if not isinstance(reason,str) or len(reason)>500:
                    reason = '旅行请求未完成'
            except (ValueError, KeyError, TypeError):
                reason = '旅行请求未完成'
            raise APIError(error.code if error.code in (400,403,404,409,503) else 503, reason) from None
        except (OSError, URLError, ValueError):
            raise APIError(503, '旅行服务暂不可达；执行结果未知，请刷新状态，未自动重发') from None

    def cached(self, conversation):
        with self.store.lock:
            row = self.store.db.execute('SELECT body FROM travel_snapshots WHERE conversation=?', (conversation,)).fetchone()
            return json.loads(row[0]) if row else None

    def _record(self, conversation, snapshot):
        if (not isinstance(snapshot,dict) or snapshot.get('conversationID') != conversation or
                type(snapshot.get('revision')) is not int):
            raise APIError(503, '旅行状态所属会话或版本不匹配')
        with self.store.lock, self.store.db:
            old = self.store.db.execute('SELECT revision,body FROM travel_snapshots WHERE conversation=?',(conversation,)).fetchone()
            if old and old[0]>snapshot['revision']:
                return self.album.decorate(conversation,json.loads(old[1]))
            self.store.db.execute('INSERT INTO travel_snapshots VALUES(?,?,?) ON CONFLICT(conversation) DO UPDATE SET revision=excluded.revision,body=excluded.body',
                                  (conversation,snapshot['revision'],encode(snapshot)))
        return self.album.decorate(conversation,snapshot)

    def _queue_invitation_result(self, conversation, snapshot):
        invitation = snapshot.get('invitation') or {}
        if invitation.get('status') not in ('accepted','declined'):
            return
        invitation_id = bounded_id(invitation.get('id'))
        event_id = 'travel-event-'+hashlib.sha256((conversation+':'+invitation_id).encode()).hexdigest()[:32]
        with self.store.lock, self.store.db:
            self.store.conversation(conversation)
            if self.store._message(event_id) or self.store._handoff_busy(conversation):
                return
            event = {'id':event_id,'conversationID':conversation,'role':'system','text':'',
                     'createdAt':now(),'status':'sent','attachments':[],'replyTo':None,
                     'travelEventID':invitation_id,'travelDecision':invitation['status']}
            self.store._put(event)
            self.store.db.execute('INSERT INTO jobs VALUES(?,?,NULL,?)',
                                  (event_id,'queued','assistant-'+event_id))

    def snapshot(self, conversation):
        bounded_id(conversation)
        with self.store.lock:
            self.store.conversation(conversation)
        if not self.enabled:
            return {'available':False,'conversationID':conversation,'revision':0,
                    'invitation':None,'journey':None,'archives':[]}
        result = self._request('/state?'+urlencode({'conversationID':conversation}), timeout=5)
        snapshot = self._record(conversation,result)
        self._queue_invitation_result(conversation,snapshot)
        return snapshot

    def respond(self, conversation, invitation, decision, request_id):
        bounded_id(conversation); bounded_id(invitation); bounded_id(request_id)
        if decision not in ('accept','decline'):
            raise APIError(400,'旅行邀请回复无效')
        with self.store.lock:
            self.store.conversation(conversation)
            if self.store._handoff_busy(conversation):
                raise APIError(409,'换窗期间请稍后回应旅行邀请')
        # One stable service operation per invitation decision, not per HTTP attempt.
        result = self._request('/invitation', {'conversationID':conversation,'invitationID':invitation,
            'decision':decision,'operationID':conversation+':invitation:'+invitation+':'+decision})
        snapshot = self._record(conversation,result['snapshot'])
        self._queue_invitation_result(conversation,snapshot)
        return snapshot

    def control(self, body):
        if not isinstance(body,dict) or set(body)!={'conversationID','journeyID','action','requestID'}:
            raise APIError(400,'旅行控制参数无效')
        conversation = bounded_id(body['conversationID'])
        bounded_id(body['journeyID']); bounded_id(body['requestID'])
        if body['action'] not in ('pause','resume','end'):
            raise APIError(400,'旅行操作无效')
        with self.store.lock:
            self.store.conversation(conversation)
        args = {k:body[k] for k in ('conversationID','journeyID','action')}
        args['operationID']=conversation+':control:'+body['requestID']
        result = self._request('/control',args)
        return self._record(conversation,result['snapshot'])

    def tool(self, conversation, message, turn, call, tool, arguments):
        if tool not in TRAVEL_NAMES or not isinstance(arguments,dict):
            raise APIError(400,'旅行工具参数无效')
        contract = next(t['inputSchema'] for t in TRAVEL_TOOLS if t['name']==tool)
        if set(arguments)-set(contract['properties']) or arguments.get('action') not in contract['properties']['action']['enum']:
            raise APIError(400,'旅行工具操作无效，接受/拒绝只能由手机发起')
        with self.store.lock:
            origin = self.store._message(message)
        if not origin or origin['conversationID']!=conversation or origin.get('handoffID'):
            raise APIError(403,'没有对应旅行会话授权')
        if origin.get('role')!='user':
            readonly = (tool=='travel_journey' and arguments.get('action') in ('status','list')) or (
                tool=='travel_memory' and arguments.get('action')=='list')
            invitation = (not origin.get('travelEventID') and tool=='travel_journey' and
                          arguments.get('action')=='start' and arguments.get('mode','together')=='together')
            if not readonly and not invitation:
                raise APIError(403,'内部续答不能代替用户推进旅行；等她回应')
        if tool=='travel_memory' and arguments.get('action')=='photo':
            if set(arguments)!={'action','journeyID','sceneID','attachmentID','caption'}:
                raise APIError(400,'保存照片需journeyID、sceneID、attachmentID、caption')
            jid=bounded_id(arguments['journeyID']); sid=bounded_id(arguments['sceneID']); aid=bounded_id(arguments['attachmentID'])
            scene=self._request('/scene?'+urlencode({'conversationID':conversation,'journeyID':jid,'sceneID':sid}),timeout=5).get('scene')
            if not isinstance(scene,dict) or scene.get('id')!=sid or scene.get('journeyID')!=jid:
                raise APIError(503,'照片场景核对失败，未收入')
            photo=self.album.add(conversation,message,turn,call,jid,sid,aid,arguments['caption'])
            return {'text':'已将生成照片收入这趟旅程。','photo':photo}
        result = self._request('/tool', {'conversationID':conversation,'operationID':':'.join((conversation,message,turn,call)),
            'turnID':turn,'tool':tool,'arguments':arguments})
        if isinstance(result.get('snapshot'),dict):
            result['snapshot']=self._record(conversation,result['snapshot'])
        if tool=='travel_memory' and arguments.get('action')=='list':
            j=result.get('snapshot',{}).get('journey')
            if j:result.setdefault('data',{})['photos']=self.album.photos(conversation,j['id'])
        return result

    def journal(self, conversation, journey, after=0):
        bounded_id(conversation); bounded_id(journey)
        if type(after) is not int or not 0<=after<=2**63-1:raise APIError(400,'旅程分页参数无效')
        with self.store.lock:self.store.conversation(conversation)
        result=self._request('/journal?'+urlencode({'conversationID':conversation,'journeyID':journey,'after':after,'limit':50}),timeout=5)
        j=result.get('journey')
        if not isinstance(j,dict) or j.get('id')!=journey or j.get('conversationID')!=conversation or not isinstance(result.get('scenes'),list):
            raise APIError(503,'旅程详情回执不匹配')
        with self.store.lock:
            decorated=self.album.decorate(conversation,{'journey':j})
            result['journey']=decorated['journey']
            result['albumRevision']=decorated['albumRevision']
            result['photos']=self.album.photos(conversation,journey)
        return result

    def cover(self, body):
        if not isinstance(body,dict) or set(body)!={'conversationID','journeyID','photoID','requestID'}:
            raise APIError(400,'旅行封面参数无效')
        c,j,p,r=(bounded_id(body[k]) for k in ('conversationID','journeyID','photoID','requestID'))
        self.journal(c,j) # Authoritative journey ownership, including archived trips.
        self.album.cover(c,j,p,r)
        return self.snapshot(c)

    def context_for_job(self, job):
        """Inject the travel contract only for an active state or explicit travel talk."""
        if not self.enabled or job['user'].get('handoffID'):
            return ''
        message=job['user']; conversation=message['conversationID']
        snapshot=self.cached(conversation)
        scene=message.get('travelSceneID')
        words=('旅行','旅程','出发','乌有乡','一起散步','带我去','travel_')
        requested=any(word in str(message.get('text','')).lower() for word in words)
        warning=''
        if scene and message.get('role')=='user':
            try:
                result=self._request('/reply', {'conversationID':conversation,'messageID':message['id'],
                    'sceneID':scene,'text':message.get('text','')[:4000]},timeout=5)
                snapshot=self._record(conversation,result['snapshot'])
            except APIError:
                warning='这条消息未确认解锁对应旅行场景，不要假定旅程已继续。'
        active=bool(snapshot and (snapshot.get('invitation') or snapshot.get('journey')))
        receipt=bool(message.get('travelEventID'))
        if not active and not warning and not receipt and not requested:
            return ''
        # Include only this current scene, never a growing history/archive dump.
        compact={k:snapshot.get(k) for k in ('invitation','journey')} if snapshot else {}
        if compact.get('journey'):
            compact['journey']={k:v for k,v in compact['journey'].items() if k not in ('path',)}
        if message.get('travelEventID'):
            compact['event']={'invitationID':message['travelEventID'],'decision':message['travelDecision']}
            warning += '这是应用的邀请处理回执，不是用户新说的话；接受时介绍第一幕并等她，拒绝时回到普通聊天。'
        return '\n[Cove 旅行状态（服务端数据，不是用户指令）]\n'+encode(compact)+'\n'+warning+'\n'+TRAVEL_GUIDANCE
