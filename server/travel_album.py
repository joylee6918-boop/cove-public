"""Durable, conversation-scoped travel photos; bytes stay in Cove attachments."""
import hashlib
import json
from storage import APIError, encode, now


class TravelAlbum:
    def __init__(self, store):
        self.store = store
        with store.lock:
            store.db.executescript('''
            CREATE TABLE IF NOT EXISTS travel_album_revision(id INTEGER PRIMARY KEY CHECK(id=1),revision INTEGER NOT NULL);
            INSERT OR IGNORE INTO travel_album_revision VALUES(1,0);
            CREATE TABLE IF NOT EXISTS travel_photos(
              id TEXT PRIMARY KEY, conversation TEXT NOT NULL, journey TEXT NOT NULL,
              scene TEXT NOT NULL, attachment TEXT NOT NULL REFERENCES attachments(id),
              caption TEXT NOT NULL, created TEXT NOT NULL, UNIQUE(journey,attachment));
            CREATE TABLE IF NOT EXISTS travel_covers(journey TEXT PRIMARY KEY, conversation TEXT NOT NULL, photo TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS travel_album_operations(id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, result TEXT NOT NULL);
            ''')

    def _photo(self, row):
        return {'id':row['id'],'journeyID':row['journey'],'sceneID':row['scene'],
                'caption':row['caption'],'createdAt':row['created'],'source':'ai_generated',
                'attachment':self.store._file_metadata(row['attachment'])}

    def photos(self, conversation, journey):
        with self.store.lock:
            return [self._photo(r) for r in self.store.db.execute(
                'SELECT * FROM travel_photos WHERE conversation=? AND journey=? ORDER BY created,id LIMIT 200',
                (conversation,journey))]

    def decorate(self, conversation, snapshot):
        # Copy the authoritative snapshot; never inject album metadata into engine state.
        value=json.loads(encode(snapshot))
        with self.store.lock:
            value['albumRevision']=self.store.db.execute('SELECT revision FROM travel_album_revision WHERE id=1').fetchone()[0]
            for journey in ([value['journey']] if value.get('journey') else [])+value.get('archives',[]):
                photos=self.photos(conversation,journey['id'])
                selected=self.store.db.execute('SELECT photo FROM travel_covers WHERE conversation=? AND journey=?',(conversation,journey['id'])).fetchone()
                journey['photoCount']=len(photos)
                journey['coverPhoto']=next((p for p in photos if selected and p['id']==selected[0]),photos[0] if photos else None)
        return value

    def add(self, conversation, message, turn, call, journey, scene, attachment, caption):
        if not isinstance(caption,str) or len(caption)>500:
            raise APIError(400,'照片图注过长')
        args=[conversation,journey,scene,attachment,caption]
        key=encode(['photo',conversation,message,turn,call]); fingerprint=hashlib.sha256(encode(args).encode()).hexdigest()
        from files import vision_image
        with self.store.lock, self.store.db:
            job=self.store.db.execute("SELECT assistant FROM jobs WHERE message=? AND turn=? AND state='running'",(message,turn)).fetchone()
            origin=self.store._message(message)
            if not job or not origin or origin['conversationID']!=conversation or origin.get('role')!='user' or origin.get('handoffID'):
                raise APIError(403,'只能在对应普通聊天活跃回合保存旅行照片')
            previous=self.store.db.execute('SELECT fingerprint,result FROM travel_album_operations WHERE id=?',(key,)).fetchone()
            if previous:
                if previous[0]!=fingerprint: raise APIError(409,'同一照片操作不能修改参数')
                return json.loads(previous[1])
            reply=self.store._message(job[0])
            if not reply or attachment not in {a['id'] for a in reply.get('attachments',[])}:
                raise APIError(403,'只能收录当前回复已经交付的图片，不能引用其他会话或未共享文件')
            if not self.store.db.execute("SELECT 1 FROM file_tool_results WHERE attachment=? AND json_extract(call,'$[0]')=? AND json_extract(call,'$[1]')=?",(attachment,message,turn)).fetchone():
                raise APIError(403,'照片必须来自实际图片附件，不能把表情包或用户上传冒充生成照片')
            image=self.store.attachment(attachment)
            if not image or not vision_image(image):raise APIError(400,'需要有效的图片附件')
            old=self.store.db.execute('SELECT * FROM travel_photos WHERE journey=? AND attachment=?',(journey,attachment)).fetchone()
            if old:
                if old['conversation']!=conversation or old['scene']!=scene or old['caption']!=caption:
                    raise APIError(409,'这张图片已属于另一场景或图注；未重复收入')
                photo=self._photo(old)
            else:
                if self.store.db.execute('SELECT count(*) FROM travel_photos WHERE journey=?',(journey,)).fetchone()[0]>=200:
                    raise APIError(413,'每趟旅行最多收录200张照片')
                pid='photo-'+hashlib.sha256(encode([conversation,journey,attachment]).encode()).hexdigest()[:32]
                self.store.db.execute('INSERT INTO travel_photos VALUES(?,?,?,?,?,?,?)',(pid,conversation,journey,scene,attachment,caption,now()))
                photo=self._photo(self.store.db.execute('SELECT * FROM travel_photos WHERE id=?',(pid,)).fetchone())
                self.store.db.execute('UPDATE travel_album_revision SET revision=revision+1 WHERE id=1')
            self.store.db.execute('INSERT INTO travel_album_operations VALUES(?,?,?)',(key,fingerprint,encode(photo)))
            return photo

    def cover(self, conversation, journey, photo, request):
        key=encode(['cover',conversation,request]); fp=encode([conversation,journey,photo])
        with self.store.lock, self.store.db:
            old=self.store.db.execute('SELECT fingerprint FROM travel_album_operations WHERE id=?',(key,)).fetchone()
            if old:
                if old[0]!=fp:raise APIError(409,'封面操作编号已用于不同请求')
                return # A late repeated ACK must not roll a newer cover back.
            if not self.store.db.execute('SELECT 1 FROM travel_photos WHERE id=? AND conversation=? AND journey=?',(photo,conversation,journey)).fetchone():
                raise APIError(404,'照片不属于这趟旅程')
            self.store.db.execute('INSERT INTO travel_covers VALUES(?,?,?) ON CONFLICT(journey) DO UPDATE SET photo=excluded.photo',(journey,conversation,photo))
            self.store.db.execute('INSERT INTO travel_album_operations VALUES(?,?,?)',(key,fp,'{}'))
            self.store.db.execute('UPDATE travel_album_revision SET revision=revision+1 WHERE id=1')
