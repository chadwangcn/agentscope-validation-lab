import { useCallback, useEffect, useRef, useState } from 'react';
import {
  Activity, BrainCircuit, Database, FlaskConical, Mic, Play, Plus, Save,
  Server, Square, Trash2, Undo2, Upload, Volume2, XCircle,
} from 'lucide-react';
import { api } from './api';
import type { Capabilities, MemoryRecord, MemoryStatus, ServiceStatus } from './types';

type Page = 'chat' | 'memories' | 'evaluations' | 'status';
const PUBLIC_BASE = '/lab';
const pageFromPath = (): Page => {
  const value = location.pathname.startsWith(`${PUBLIC_BASE}/`)
    ? location.pathname.slice(PUBLIC_BASE.length + 1)
    : location.pathname.slice(1);
  if (value === 'ui/status') return 'status';
  return value === 'memories' || value === 'evaluations' ? value : 'chat';
};
const PATHS: Record<Page, string> = {
  chat: `${PUBLIC_BASE}/chat`,
  memories: `${PUBLIC_BASE}/memories`,
  evaluations: `${PUBLIC_BASE}/evaluations`,
  status: `${PUBLIC_BASE}/ui/status`,
};

const NAV: Array<[Page, string, typeof Mic]> = [
  ['chat', '实时对话', Mic], ['memories', '记忆工作台', Database],
  ['evaluations', '实验评测', FlaskConical], ['status', '系统状态', Server],
];

export function App() {
  const [page, setPage] = useState<Page>(pageFromPath);
  const [space, setSpace] = useState('test_child_001');
  const [capabilities, setCapabilities] = useState<Capabilities>();
  const navigate = (next: Page) => { history.pushState({}, '', PATHS[next]); setPage(next); };
  useEffect(() => { const fn = () => setPage(pageFromPath()); addEventListener('popstate', fn); return () => removeEventListener('popstate', fn); }, []);
  useEffect(() => { api.capabilities().then(setCapabilities).catch(() => setCapabilities(undefined)); }, []);
  const asrReady = capabilities?.asr.status === 'validated';
  return <div className="app-shell">
    <aside className="sidebar">
      <div className="brand">Talk · Think<br />Memory Lab</div>
      <nav>{NAV.map(([key, label, Icon]) => <button key={key} className={page === key ? 'active' : ''} onClick={() => navigate(key)}><Icon />{label}</button>)}</nav>
      <div className="connection"><span />实验环境 · 仅合成数据</div>
    </aside>
    <main className="main">
      <header className="context-bar">
        <label>对话模型<select disabled><option>未配置</option></select></label>
        <label>记忆空间<select value={space} onChange={(event) => setSpace(event.target.value)}><option value="test_child_001">测试儿童 A</option><option value="test_child_002">测试儿童 B</option><option value="blank_test">空白测试空间</option></select></label>
        <label>语音能力<select disabled><option>{asrReady ? '豆包 ASR（已验证）' : '未配置'}</option></select></label>
        <label>记忆能力<select disabled><option>人工发布生命周期（已验证）</option></select></label>
      </header>
      {page === 'chat' ? <ChatPage space={space} capabilities={capabilities} /> : null}
      {page === 'memories' ? <MemoriesPage space={space} /> : null}
      {page === 'evaluations' ? <EvaluationPage /> : null}
      {page === 'status' ? <StatusPage /> : null}
    </main>
  </div>;
}

function ChatPage({ space, capabilities }: { space: string; capabilities?: Capabilities }) {
  const [recording, setRecording] = useState(false);
  const [audioUrl, setAudioUrl] = useState<string>();
  const [events, setEvents] = useState<string[]>([]);
  const [recordingError, setRecordingError] = useState('');
  const [transcript, setTranscript] = useState('');
  const [transcribing, setTranscribing] = useState(false);
  const audioInput = useRef<HTMLInputElement | null>(null);
  const recorder = useRef<MediaRecorder | undefined>(undefined);
  const chunks = useRef<Blob[]>([]);
  const recordingAvailable = window.isSecureContext
    && typeof navigator.mediaDevices?.getUserMedia === 'function'
    && typeof MediaRecorder !== 'undefined';
  useEffect(() => {
    const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const socket = new WebSocket(`${protocol}//${location.host}${PUBLIC_BASE}/ws/v1/spaces/${space}/events`);
    socket.onmessage = (event) => setEvents((current) => [JSON.parse(event.data).event_type, ...current].slice(0, 8));
    return () => socket.close();
  }, [space]);
  const start = async () => {
    if (!recordingAvailable) return;
    setRecordingError('');
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      const next = new MediaRecorder(stream); chunks.current = [];
      next.ondataavailable = (event) => chunks.current.push(event.data);
      next.onstop = () => { setAudioUrl(URL.createObjectURL(new Blob(chunks.current, { type: next.mimeType }))); stream.getTracks().forEach((track) => track.stop()); };
      recorder.current = next; next.start(); setRecording(true);
    } catch (reason) {
      setRecordingError(reason instanceof Error ? reason.message : '浏览器未授予麦克风权限');
    }
  };
  const stop = () => { recorder.current?.stop(); setRecording(false); };
  const uploadAudio = async (file?: File) => {
    if (!file) return;
    setRecordingError(''); setTranscript(''); setTranscribing(true);
    setAudioUrl(URL.createObjectURL(file));
    try {
      const result = await api.transcribe(space, file);
      setTranscript(result.transcript);
    } catch (reason) {
      setRecordingError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      setTranscribing(false);
      if (audioInput.current) audioInput.current.value = '';
    }
  };
  const asrReady = capabilities?.asr.status === 'validated';
  return <section className="chat-grid">
    <div className="conversation">
      <div className={`speech-gate ${asrReady ? 'ready' : ''}`}><Volume2 />{asrReady ? '豆包 ASR 已经真实验证 · 对话模型与 TTS 未配置' : 'ASR 未配置 · 对话与 Talker 保持禁用'}</div>
      <div className="empty-conversation"><BrainCircuit /><h1>验证真实语音转写</h1><p>{asrReady ? '上传不含真实个人数据的 WAV、MP3 或 OGG Opus，页面将调用服务端豆包 ASR 并显示转写。' : '当前没有通过验证的 ASR 能力，上传识别已禁用。'}</p></div>
      <div className="record-rail">
        <button className={`mic ${recording ? 'recording' : ''}`} onClick={recording ? stop : start} disabled={!recordingAvailable} title={recordingAvailable ? '开始录音' : 'HTTP 域名下浏览器禁止麦克风采集'}>{recording ? <Square /> : <Mic />}</button>
        <div><strong>{recording ? '正在录音' : recordingAvailable ? '按下开始说话' : '麦克风需要安全上下文'}</strong><small>{space} · {recordingAvailable ? '音频仅保留在当前浏览器' : '请使用 HTTPS 或 localhost SSH 隧道'}</small></div>
        <input ref={audioInput} type="file" accept=".wav,.mp3,.ogg,audio/wav,audio/mpeg,audio/ogg" hidden onChange={(event) => uploadAudio(event.target.files?.[0])} />
        <button className="secondary" disabled={!asrReady || transcribing} onClick={() => audioInput.current?.click()}><Upload />{transcribing ? '识别中…' : '上传音频识别'}</button>
        <button className="danger" onClick={stop} disabled={!recording}><XCircle />打断</button>
      </div>
      {recordingError ? <div className="error recording-error">麦克风启动失败：{recordingError}</div> : null}
      {audioUrl ? <div className="audio-row"><Play /><audio controls src={audioUrl} /></div> : null}
      {transcript ? <div className="transcript"><small>真实 ASR 转写</small><p>{transcript}</p></div> : null}
      <div className="trace"><h2>实时事件轨迹</h2>{events.length ? events.map((event, index) => <div key={`${event}-${index}`}><Activity />{event}</div>) : <p>等待 WebSocket 事件…</p>}</div>
    </div>
    <aside className="inspector"><h2>本轮记忆</h2><div className="inspector-empty">尚无召回证据。模型调用后，这里将显示 ReME 来源、图谱事实、Context Pack 与反馈入口。</div></aside>
  </section>;
}

function MemoriesPage({ space }: { space: string }) {
  const [items, setItems] = useState<MemoryRecord[]>([]);
  const [selected, setSelected] = useState<MemoryRecord>();
  const [title, setTitle] = useState(''); const [content, setContent] = useState('');
  const [error, setError] = useState(''); const [busy, setBusy] = useState(false);
  const uploadInput = useRef<HTMLInputElement | null>(null);
  const load = useCallback(async () => { const data = await api.list(space); setItems(data.items); setSelected((current) => data.items.find((item) => item.id === current?.id) ?? data.items[0]); }, [space]);
  useEffect(() => { load().catch((reason) => setError(reason.message)); }, [load]);
  useEffect(() => { setTitle(selected?.title ?? ''); setContent(selected?.content ?? ''); }, [selected]);
  const act = async (work: () => Promise<unknown>) => { setBusy(true); setError(''); try { await work(); await load(); } catch (reason) { setError(reason instanceof Error ? reason.message : String(reason)); } finally { setBusy(false); } };
  const transition = (status: MemoryStatus) => selected && act(() => api.transition(selected, status));
  const editable = !selected || selected.status === 'draft' || selected.status === 'withdrawn';
  const upload = async (file?: File) => {
    if (!file) return;
    let uploadedContent = '';
    if (file.name.toLowerCase().endsWith('.zip')) {
      const { default: JSZip } = await import('jszip');
      const archive = await JSZip.loadAsync(file);
      const markdown = Object.values(archive.files).find((entry) => !entry.dir && entry.name.toLowerCase().endsWith('/memory.md'))
        ?? Object.values(archive.files).find((entry) => !entry.dir && entry.name.toLowerCase().endsWith('.md'));
      if (!markdown) throw new Error('ZIP 中未找到 memory.md');
      uploadedContent = await markdown.async('text');
    } else {
      uploadedContent = await file.text();
    }
    const frontmatterTitle = uploadedContent.match(/^title:\s*(.+)$/m)?.[1]?.trim();
    setTitle(frontmatterTitle ?? file.name.replace(/\.(md|zip)$/i, ''));
    setContent(uploadedContent);
    setSelected(undefined);
  };
  return <section className="memory-grid">
    <aside className="library"><div className="section-title"><div><h1>记忆库</h1><small>{items.length} 条 · {space}</small></div><button className="icon-button" onClick={() => { setSelected(undefined); setTitle(''); setContent(''); }}><Plus /></button></div>
      <div className="memory-list">{items.map((item) => <button key={item.id} className={selected?.id === item.id ? 'selected' : ''} onClick={() => setSelected(item)}><strong>{item.title}</strong><span className={`status ${item.status}`}>{statusLabel(item.status)}</span><small>v{item.version} · {new Date(item.updated_at).toLocaleString()}</small></button>)}</div>
    </aside>
    <div className="editor"><div className="editor-head"><div><h1>{selected?.status === 'purged' ? '清除凭证' : selected ? '编辑记忆' : '新建记忆'}</h1><small>原始图片与 Markdown 是事实源；派生索引可重建</small></div><><input ref={uploadInput} type="file" accept=".md,.zip,text/markdown,application/zip" hidden onChange={(event) => upload(event.target.files?.[0]).catch((reason) => setError(reason.message))} /><button className="secondary" onClick={() => uploadInput.current?.click()}><Upload />上传 ZIP / MD</button></></div>
      {error ? <div className="error">{error}</div> : null}
      {!editable && selected ? <div className="state-note">当前记录为“{statusLabel(selected.status)}”，内容只读。请使用下方生命周期操作；已清除记录仅保留不可还原的审计墓碑。</div> : null}
      <label>标题<input value={title} onChange={(event) => setTitle(event.target.value)} readOnly={!editable} /></label>
      <label className="markdown-label">Markdown<textarea value={content} onChange={(event) => setContent(event.target.value)} spellCheck={false} readOnly={!editable} /></label>
      <div className="action-rail">
        {editable ? <button disabled={busy || !title || !content} onClick={() => act(() => selected ? api.update(selected, title, content) : api.create(space, title, content))}><Save />保存草稿</button> : null}
        {selected?.status === 'draft' ? <button disabled={busy} onClick={() => transition('review')}>提交待发布</button> : null}
        {selected?.status === 'review' ? <button className="primary" disabled={busy} onClick={() => transition('published')}>确认发布</button> : null}
        {selected?.status === 'published' ? <button disabled={busy} onClick={() => transition('withdrawn')}>撤回发布</button> : null}
        {selected?.status === 'withdrawn' ? <><button disabled={busy} onClick={() => transition('published')}><Undo2 />恢复发布</button><button className="danger" disabled={busy} onClick={() => act(() => api.trash(selected))}><Trash2 />移入回收站</button></> : null}
        {selected?.status === 'draft' ? <button className="danger" disabled={busy} onClick={() => act(() => api.trash(selected))}><Trash2 />移入回收站</button> : null}
        {selected?.status === 'trashed' ? <><button disabled={busy} onClick={() => transition('withdrawn')}><Undo2 />恢复</button><button className="danger" disabled={busy} onClick={() => confirm(`永久删除 ${selected.id}？`) && act(() => api.purge(selected))}>永久删除</button></> : null}
      </div>
    </div>
    <aside className="inspector"><h2>发布预览</h2><div className="inspector-empty">保存后端解析结果将在这里展示 ReME 摘要、实体、关系、事件、冲突候选及来源。所有候选需人工确认后发布。</div></aside>
  </section>;
}

function EvaluationPage() { return <div className="placeholder"><FlaskConical /><h1>实验评测</h1><p>V0/V1 与 M0-M3 的真实轨迹将在模型适配器和评测 API 接入后显示；当前不生成虚构指标。</p></div>; }

function StatusPage() {
  const [status, setStatus] = useState<ServiceStatus>(); const [error, setError] = useState('');
  useEffect(() => { api.status().then(setStatus).catch((reason) => setError(reason.message)); }, []);
  return <div className="status-page"><h1>系统状态</h1>{error ? <div className="error">{error}</div> : null}{status ? <div className="status-table"><StatusRow label="Lab API" ok={status.status === 'ok'} detail={`v${status.service_version}`} /><StatusRow label="豆包 ASR" ok={status.capabilities.asr.status === 'validated'} detail={status.capabilities.asr.status === 'validated' ? '真实调用已验证' : '未配置'} /><StatusRow label="ReME" ok={status.reme.reachable} detail={status.packages['reme-ai'] ?? '未安装'} /><StatusRow label="Neo4j" ok={status.neo4j.reachable} detail={status.packages.neo4j ?? '未安装'} /><StatusRow label="SQLite / JSONL" ok detail="本地持久化" /></div> : <p>读取真实服务状态…</p>}</div>;
}
function StatusRow({ label, ok, detail }: { label: string; ok: boolean; detail: string }) { return <div><span className={ok ? 'dot ok' : 'dot'} /><strong>{label}</strong><span>{detail}</span><b>{ok ? '正常' : '不可用'}</b></div>; }
function statusLabel(status: MemoryStatus) { return ({ draft: '草稿', review: '待发布', published: '已发布', withdrawn: '已撤回', trashed: '回收站', purged: '已清除' } as const)[status]; }
