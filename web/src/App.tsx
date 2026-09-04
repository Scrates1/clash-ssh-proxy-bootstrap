import { FormEvent, ReactNode, useEffect, useMemo, useRef, useState } from 'react'
import { fetchState, hasManagerSession, runAction, sendHeartbeat } from './api'
import type { ManagerActionOptions } from './api'
import { useI18n } from './i18n'
import type { HealthState, LogEntry, ManagerState, Target, TargetForm, TaskState } from './types'

type IconName = 'overview' | 'servers' | 'activity' | 'settings' | 'refresh' | 'plus' | 'arrow' | 'chevron' | 'more' | 'edit' | 'trash' | 'key' | 'external' | 'check' | 'warning' | 'terminal' | 'pulse' | 'lock'

type TargetWizardStage = 'details' | 'checking-ssh' | 'ssh-auth' | 'verifying-ssh' | 'installing'
type BridgeStatus = 'checking' | 'connected' | 'offline'

function Icon({ name, size = 18 }: { name: IconName; size?: number }) {
  const paths: Record<IconName, ReactNode> = {
    overview: <><rect x="3" y="3" width="7" height="7" rx="1" /><rect x="14" y="3" width="7" height="7" rx="1" /><rect x="3" y="14" width="7" height="7" rx="1" /><rect x="14" y="14" width="7" height="7" rx="1" /></>,
    servers: <><rect x="3" y="4" width="18" height="6" rx="2" /><rect x="3" y="14" width="18" height="6" rx="2" /><path d="M7 7h.01M7 17h.01M11 7h6M11 17h6" /></>,
    activity: <><path d="M3 12h4l2.2-6 4.1 12 2.2-6H21" /><path d="M3 4v16M21 4v16" opacity=".25" /></>,
    settings: <><path d="M12 3v3M12 18v3M3 12h3M18 12h3M5.6 5.6l2.1 2.1M16.3 16.3l2.1 2.1M18.4 5.6l-2.1 2.1M7.7 16.3l-2.1 2.1" /><circle cx="12" cy="12" r="4" /></>,
    refresh: <><path d="M20 11a8 8 0 0 0-14.7-4L3 10" /><path d="M3 5v5h5M4 13a8 8 0 0 0 14.7 4L21 14" /><path d="M21 19v-5h-5" /></>,
    plus: <><path d="M12 5v14M5 12h14" /></>,
    arrow: <><path d="M5 12h13M13 6l6 6-6 6" /></>,
    chevron: <path d="m8 10 4 4 4-4" />,
    more: <><circle cx="5" cy="12" r="1" fill="currentColor" stroke="none" /><circle cx="12" cy="12" r="1" fill="currentColor" stroke="none" /><circle cx="19" cy="12" r="1" fill="currentColor" stroke="none" /></>,
    edit: <><path d="m4 16-.8 4.8L8 20l10.7-10.7a2.5 2.5 0 0 0-3.5-3.5L4.5 16.5Z" /><path d="m13.5 7.5 3 3" /></>,
    trash: <><path d="M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3" /></>,
    key: <><circle cx="8" cy="15" r="4" /><path d="m11 12 7-7 3 3-2 2 2 2-2 2-2-2-2 2" /></>,
    external: <><path d="M14 5h5v5M19 5l-8 8" /><path d="M19 14v4a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2h4" /></>,
    check: <path d="m5 12 4.5 4.5L19 7" />,
    warning: <><path d="m12 4 9 16H3L12 4Z" /><path d="M12 9v5M12 17h.01" /></>,
    terminal: <><rect x="3" y="4" width="18" height="16" rx="2" /><path d="m7 9 3 3-3 3M13 15h4" /></>,
    pulse: <><path d="M3 12h4l2-5 4 10 2-5h6" /></>,
    lock: <><rect x="5" y="10" width="14" height="10" rx="2" /><path d="M8 10V7a4 4 0 0 1 8 0v3" /></>,
  }

  return <svg className="icon" width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">{paths[name]}</svg>
}

const now = () => new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })

const formatTime = (value: string) => {
  if (!value) return '—'
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? '—' : date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
}

const demoState: ManagerState = {
  mode: 'demo',
  configPath: '%LOCALAPPDATA%\\ClashSshProxy\\config.json',
  localProxy: { host: '127.0.0.1', port: 7897, up: true },
  checkedAt: new Date().toISOString(),
  targets: [
    {
      id: 'tgt-demo-tokyo', name: 'tokyo-edge', host: '203.0.113.24', user: 'proxy', destination: 'proxy@203.0.113.24',
      task: 'ClashProxyTo-tokyo-edge', taskState: 'Running', enabled: true, ssh: 'OK', proxy: 'OK', remotePort: 17897, sshPort: 22,
      identityFile: '%LOCALAPPDATA%\\ClashSshProxy\\keys\\tgt-demo-tokyo.ed25519', identityManaged: true, noProxyExtra: [], durationMs: 84,
    },
    {
      id: 'tgt-demo-home', name: 'home-lab', host: '192.0.2.17', user: 'ubuntu', destination: 'ubuntu@192.0.2.17',
      task: 'ClashProxyTo-home-lab', taskState: 'Running', enabled: true, ssh: 'OK', proxy: 'FAIL', remotePort: 17898, sshPort: 22,
      identityFile: '%LOCALAPPDATA%\\ClashSshProxy\\keys\\tgt-demo-home.ed25519', identityManaged: true, noProxyExtra: ['*.internal'], durationMs: 1120,
    },
    {
      id: 'tgt-demo-staging', name: 'staging', host: '198.51.100.8', user: 'deploy', destination: 'deploy@198.51.100.8',
      task: 'ClashProxyTo-staging', taskState: 'Disabled', enabled: false, ssh: 'UNKNOWN', proxy: 'BLOCKED', remotePort: 17899, sshPort: 2222,
      identityFile: '%LOCALAPPDATA%\\ClashSshProxy\\keys\\tgt-demo-staging.ed25519', identityManaged: true, noProxyExtra: [], durationMs: 640,
    },
  ],
  logs: [
    { id: 'demo-1', time: now(), message: 'Manager ready. Local Clash proxy is listening.', tone: 'success' },
    { id: 'demo-2', time: now(), message: 'Health check completed for 3 targets.', tone: 'default' },
    { id: 'demo-3', time: now(), message: 'home-lab proxy probe returned FAIL.', tone: 'warning' },
  ],
}

const emptyState: ManagerState = {
  mode: 'live',
  configPath: '—',
  localProxy: { host: '127.0.0.1', port: 7897, up: false },
  checkedAt: '',
  targets: [],
  logs: [],
}

const demoPreview = !hasManagerSession && new URLSearchParams(window.location.search).get('demo') === '1'

function normalizeState(raw: ManagerState): ManagerState {
  const source = raw as unknown as Record<string, unknown>
  const get = (value: Record<string, unknown>, ...keys: string[]) => keys.map((key) => value[key]).find((item) => item !== undefined)
  const rawTargets = Array.isArray(source.targets)
    ? source.targets.filter((item) => item !== null && typeof item === 'object' && !Array.isArray(item))
    : []
  const targets = rawTargets.map((item, index) => {
    const value = item as Record<string, unknown>
    const name = String(get(value, 'name', 'Name') ?? `target-${index + 1}`)
    const host = String(get(value, 'host', 'Host') ?? '')
    const user = String(get(value, 'user', 'User') ?? '')
    return {
      id: String(get(value, 'id', 'Id') ?? name),
      name,
      host,
      user,
      destination: String(get(value, 'destination', 'Destination') ?? `${user}@${host}`),
      task: String(get(value, 'task', 'Task', 'taskName', 'TaskName') ?? '—'),
      taskState: String(get(value, 'taskState', 'TaskState') ?? 'Unknown') as TaskState,
      enabled: Boolean(get(value, 'enabled', 'Enabled')),
      ssh: String(get(value, 'ssh', 'SSH') ?? 'UNKNOWN') as HealthState,
      proxy: String(get(value, 'proxy', 'Proxy') ?? 'UNKNOWN') as HealthState,
      remotePort: Number(get(value, 'remotePort', 'RemotePort') ?? 0),
      sshPort: Number(get(value, 'sshPort', 'SshPort') ?? 22),
      identityFile: String(get(value, 'identityFile', 'IdentityFile') ?? '~/.ssh/id_ed25519'),
      identityManaged: Boolean(get(value, 'identityManaged', 'IdentityManaged')),
      noProxyExtra: Array.isArray(get(value, 'noProxyExtra', 'NoProxyExtra')) ? get(value, 'noProxyExtra', 'NoProxyExtra') as string[] : [],
      checkedAt: String(get(value, 'checkedAt', 'CheckedAt') ?? ''),
      durationMs: Number(get(value, 'durationMs', 'DurationMs') ?? 0),
    } satisfies Target
  })
  return {
    mode: source.mode === 'demo' ? 'demo' : 'live',
    configPath: String(source.configPath ?? ''),
    localProxy: {
      host: String((source.localProxy as Record<string, unknown> | undefined)?.host ?? '127.0.0.1'),
      port: Number((source.localProxy as Record<string, unknown> | undefined)?.port ?? 7897),
      up: Boolean((source.localProxy as Record<string, unknown> | undefined)?.up),
    },
    targets,
    logs: Array.isArray(source.logs) ? source.logs as LogEntry[] : [],
    checkedAt: String(source.checkedAt ?? ''),
  }
}

function statusLabel(status: HealthState) {
  return status === 'OK' ? 'Healthy' : status === 'FAIL' ? 'Failed' : status === 'BLOCKED' ? 'Blocked' : status === 'LEAK' ? 'Leak detected' : status === 'CHECKING' ? 'Checking' : status === 'RECOVERING' ? 'Recovering' : status === 'DISABLED' ? 'Disabled' : 'Unknown'
}

function StatusBadge({ status, compact = false }: { status: HealthState; compact?: boolean }) {
  const { t } = useI18n()
  const tone = status === 'OK' ? 'good' : status === 'FAIL' || status === 'LEAK' ? 'bad' : status === 'BLOCKED' || status === 'DISABLED' ? 'muted' : 'pending'
  return <span className={`status-badge ${tone} ${compact ? 'compact' : ''}`}><span className="status-dot" />{t(statusLabel(status))}</span>
}

function TaskBadge({ state }: { state: TaskState }) {
  const { t } = useI18n()
  const tone = state === 'Running' ? 'good' : state === 'Missing' ? 'bad' : state === 'Disabled' ? 'muted' : 'pending'
  return <span className={`task-badge ${tone}`}><span className="status-dot" />{t(state)}</span>
}

function StatCard({ label, value, hint, icon, tone }: { label: string; value: string | number; hint: string; icon: IconName; tone: 'blue' | 'green' | 'amber' | 'violet' }) {
  return <article className="stat-card">
    <div className={`stat-icon ${tone}`}><Icon name={icon} size={19} /></div>
    <div className="stat-copy"><span>{label}</span><strong>{value}</strong><small>{hint}</small></div>
  </article>
}

function Toggle({ enabled, onChange, disabled = false }: { enabled: boolean; onChange: () => void; disabled?: boolean }) {
  const { t } = useI18n()
  return <button type="button" className={`toggle ${enabled ? 'is-on' : ''}`} aria-label={enabled ? t('Disable proxy') : t('Enable proxy')} aria-pressed={enabled} disabled={disabled} onClick={(event) => { event.stopPropagation(); onChange() }}><span /></button>
}

function EmptyState({ onAdd }: { onAdd: () => void }) {
  const { t } = useI18n()
  return <div className="empty-state"><div className="empty-icon"><Icon name="servers" size={24} /></div><h3>{t('No Linux targets yet')}</h3><p>{t('Add your first target to start managing a secure SSH proxy tunnel.')}</p><button className="button primary" onClick={onAdd}><Icon name="plus" size={16} />{t('Add target')}</button></div>
}

function LoadingState() {
  const { t } = useI18n()
  return <div className="empty-state loading-state" role="status" aria-live="polite"><div className="empty-icon"><Icon name="refresh" size={24} /></div><h3>{t('Loading live manager data…')}</h3><p>{t('Waiting for the manager bridge to return current status.')}</p></div>
}

function newTargetId() {
  const uuid = typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function'
    ? crypto.randomUUID().replace(/-/g, '')
    : Date.now().toString(16) + Math.random().toString(16).slice(2)
  return 'tgt-' + uuid
}

function targetToForm(target?: Target): TargetForm {
  return {
    id: target?.id ?? newTargetId(), name: target?.name ?? '', host: target?.host ?? '', user: target?.user ?? '', sshPort: target?.sshPort ?? 22,
    identityFile: target?.identityFile ?? '', remoteProxyPort: target?.remotePort ?? 17897,
    taskName: target?.task ?? '', noProxyExtra: target?.noProxyExtra.join(', ') ?? '',
  }
}

interface TargetModalProps {
  target?: Target
  onClose: () => void
  onSubmit: (form: TargetForm) => void
  busy: boolean
  wizardStage: TargetWizardStage
  wizardMessage: string
  wizardError: boolean
  onBootstrapSsh: (form: TargetForm) => void
  onVerifySsh: (form: TargetForm) => void
  onInstallTarget: (form: TargetForm) => void
  onBackToDetails: () => void
}

function WizardSteps({ stage }: { stage: TargetWizardStage }) {
  const { t } = useI18n()
  const current = stage === 'details' ? 1 : stage === 'installing' ? 3 : 2
  const steps: Array<[number, string]> = [[1, 'Connection details'], [2, 'SSH key setup'], [3, 'Install & verify']]
  return <div className="wizard-steps" aria-label={t('Add server steps')}>
    {steps.map(([number, label]) => <div className={`wizard-step ${number === current ? 'active' : number < current ? 'complete' : ''}`} key={number}><span>{number < current ? '✓' : number}</span><strong>{t(label)}</strong></div>)}
  </div>
}

function WizardStatus({ stage, message, error }: { stage: TargetWizardStage; message: string; error: boolean }) {
  const { t } = useI18n()
  const content = error
    ? {
        icon: 'warning' as IconName,
        title: stage === 'installing' ? 'Installation failed' : stage === 'checking-ssh' ? 'Unable to prepare SSH access.' : 'Unable to open SSH setup.',
        description: 'Check the message below and try again.',
      }
    : stage === 'checking-ssh'
    ? { icon: 'refresh' as IconName, title: 'Checking SSH access…', description: 'The manager is checking key login before touching the Linux host.' }
    : stage === 'ssh-auth'
      ? { icon: 'key' as IconName, title: 'SSH key login needs one-time setup.', description: 'A separate PowerShell window will open. Password characters stay hidden while you type or paste; press Enter when finished. If Ctrl+V does not paste, use right-click or Shift+Insert. The password is never stored.' }
      : stage === 'verifying-ssh'
        ? { icon: 'check' as IconName, title: 'Verify SSH access', description: 'Finish the SSH setup window, then verify the connection here.' }
        : { icon: 'pulse' as IconName, title: error ? 'Installation failed' : 'Installing Linux integration and starting the tunnel…', description: 'The tunnel will be checked before this window closes.' }
  return <div className="wizard-status"><div className={'wizard-status-icon ' + (error ? 'error' : '')}><Icon name={content.icon} size={26} /></div><h3>{t(content.title)}</h3><p>{t(content.description)}</p>{message && <div className={'wizard-message ' + (error ? 'error' : '')}>{message}</div>}</div>
}

function TargetModal({ target, onClose, onSubmit, busy, wizardStage, wizardMessage, wizardError, onBootstrapSsh, onVerifySsh, onInstallTarget, onBackToDetails }: TargetModalProps) {
  const { t } = useI18n()
  const [form, setForm] = useState<TargetForm>(() => targetToForm(target))
  const edit = Boolean(target)
  const [advancedOpen, setAdvancedOpen] = useState(false)
  const showDetails = edit || wizardStage === 'details'
  const update = (key: keyof TargetForm, value: string) => setForm((current) => ({ ...current, [key]: key === 'sshPort' || key === 'remoteProxyPort' ? Number(value) : value }))
  const submit = (event: FormEvent) => { event.preventDefault(); if (showDetails) onSubmit(form) }
  return <div className="modal-backdrop" onMouseDown={(event) => { if (event.target === event.currentTarget && !busy) onClose() }}>
    <form className="modal-card" onSubmit={submit}>
      <div className="modal-header"><div><span className="eyebrow">{edit ? t('TARGET SETTINGS') : t('NEW TARGET')}</span><h2>{edit ? t('Edit {name}', { name: target?.name ?? '' }) : t('Add Linux target')}</h2><p>{edit ? t('Connection details are kept in your private local configuration.') : t('Add a Linux server and route its account traffic through this PC’s Clash proxy.')}</p></div><button type="button" className="icon-button" onClick={onClose} disabled={busy} aria-label={t('Close')}><span>×</span></button></div>
      {!edit && <WizardSteps stage={wizardStage} />}
      {showDetails ? <>
        <div className="form-grid">
          <label><span>{t('Target name')}</span><input required pattern="[A-Za-z0-9][A-Za-z0-9._-]*" readOnly={edit} disabled={busy} value={form.name} onChange={(event) => update('name', event.target.value)} placeholder="edge-prod" /></label>
          <label><span>{t('Linux host / IP')}</span><input required disabled={busy} value={form.host} onChange={(event) => update('host', event.target.value)} placeholder="203.0.113.10" /></label>
          <label><span>{t('Linux user')}</span><input required disabled={busy} value={form.user} onChange={(event) => update('user', event.target.value)} placeholder="ubuntu" /></label>
          <label><span>{t('SSH port')}</span><input required type="number" min="1" max="65535" disabled={busy} value={form.sshPort} onChange={(event) => update('sshPort', event.target.value)} /></label>
          <label><span>{t('Remote proxy port')}</span><input required type="number" min="1" max="65535" disabled={busy} value={form.remoteProxyPort} onChange={(event) => update('remoteProxyPort', event.target.value)} /></label>
          <label><span>{t('Scheduled task')}</span><input disabled={busy} value={form.taskName} onChange={(event) => update('taskName', event.target.value)} placeholder="ClashProxyTo-edge-prod" /></label>
          <label className="wide"><span>{t('Extra NO_PROXY')} <em>{t('optional')}</em></span><input disabled={busy} value={form.noProxyExtra} onChange={(event) => update('noProxyExtra', event.target.value)} placeholder="localhost, *.internal" /></label>
        </div>
        <button type="button" className="advanced-toggle" aria-expanded={advancedOpen} onClick={() => setAdvancedOpen((open) => !open)} disabled={busy}><span>{t('Advanced SSH settings')}</span><Icon name="chevron" size={16} /></button>
        {advancedOpen && <div className="advanced-panel"><label className="wide"><span>{t('SSH private key path')} <em>{t('optional')}</em></span><input disabled={busy} value={form.identityFile} onChange={(event) => update('identityFile', event.target.value)} placeholder="%LOCALAPPDATA%\\ClashSshProxy\\keys\\&lt;target-id&gt;.ed25519" /></label><p className="field-help">{t('Leave empty to generate a dedicated Ed25519 key for this target.')}</p></div>}
        {!edit && <div className="notice"><Icon name="key" size={17} /><span>{t('A dedicated Ed25519 key will be generated automatically. The manager will ask for a Linux password only once if needed, and never store it.')}</span></div>}
      </> : <WizardStatus stage={wizardStage} message={wizardMessage} error={wizardError} />}
      <div className="modal-actions">
        <button type="button" className="button ghost" onClick={onClose} disabled={busy}>{t('Cancel')}</button>
        {!edit && wizardStage !== 'details' && wizardStage !== 'installing' && <button type="button" className="button ghost" onClick={onBackToDetails} disabled={busy}>{t('Back')}</button>}
        {!edit && wizardStage === 'checking-ssh' && !busy && <button type="button" className="button primary" onClick={() => onSubmit(form)}>{t('Retry SSH check')}<Icon name="arrow" size={16} /></button>}
        {!edit && wizardStage === 'ssh-auth' && <button type="button" className="button primary" onClick={() => onBootstrapSsh(form)} disabled={busy}>{t('Open SSH setup')}<Icon name="external" size={16} /></button>}
        {!edit && wizardStage === 'verifying-ssh' && <><button type="button" className="button ghost" onClick={() => onBootstrapSsh(form)} disabled={busy}>{t('Open SSH setup')}</button><button type="button" className="button primary" onClick={() => onVerifySsh(form)} disabled={busy}>{t('Verify SSH')}<Icon name="check" size={16} /></button></>}
        {!edit && wizardStage === 'installing' && !busy && wizardMessage && <><button type="button" className="button ghost" onClick={onBackToDetails}>{t('Edit connection details')}</button><button type="button" className="button primary" onClick={() => onInstallTarget(form)}>{t('Retry installation')}<Icon name="refresh" size={16} /></button></>}
        {showDetails && <button type="submit" className="button primary" disabled={busy}>{busy ? edit ? t('Saving…') : t('Checking SSH access…') : edit ? t('Save changes') : t('Continue to SSH check')}<Icon name="arrow" size={16} /></button>}
      </div>
    </form>
  </div>
}

function LanguageSwitch() {
  const { t, locale, setLocale } = useI18n()
  return <div className="locale-switch" aria-label={t('Language')}><button type="button" className={locale === 'en' ? 'active' : ''} aria-label={t('English')} aria-pressed={locale === 'en'} onClick={() => setLocale('en')}>EN</button><span>/</span><button type="button" className={locale === 'zh-CN' ? 'active' : ''} aria-label={t('Chinese')} aria-pressed={locale === 'zh-CN'} onClick={() => setLocale('zh-CN')}>中</button></div>
}

function ErrorBanner({ message, note, onDismiss, onRetry }: { message: string; note?: string; onDismiss: () => void; onRetry?: () => void }) {
  const { t } = useI18n()
  return <div className="error-banner"><Icon name="warning" size={18} /><div className="error-copy"><span>{message}</span>{note && <small>{note}</small>}</div><div className="error-actions">{onRetry && <button type="button" onClick={onRetry}>{t('Retry')}</button>}<button type="button" onClick={onDismiss}>{t('Dismiss')}</button></div></div>
}

interface TargetTableProps {
  targets: Target[]
  selected?: Target
  search: string
  loading: boolean
  busy: boolean
  onSearch: (value: string) => void
  onHealthCheck: () => void
  onAdd: () => void
  onSelect: (target: Target) => void
  onToggle: (target: Target) => void
}

function TargetTable({ targets, selected, search, loading, busy, onSearch, onHealthCheck, onAdd, onSelect, onToggle }: TargetTableProps) {
  const { t } = useI18n()
  return <section className="targets-section"><div className="section-heading"><div><span className="eyebrow">{t('MANAGED TARGETS')}</span><h2>{t('Your Linux destinations')}</h2></div><div className="section-tools"><div className="search-box"><span>⌕</span><input value={search} onChange={(event) => onSearch(event.target.value)} placeholder={t('Search targets')} /></div><button className="button ghost small" onClick={onHealthCheck} disabled={loading || busy}><Icon name="pulse" size={15} />{t('Health check')}</button></div></div><div className="table-shell">{targets.length === 0 ? loading ? <LoadingState /> : <EmptyState onAdd={onAdd} /> : <div className="target-table"><div className="table-head"><span>{t('Target')}</span><span>{t('Connection')}</span><span>{t('Task')}</span><span>{t('Proxy health')}</span><span>{t('Access')}</span><span /></div>{targets.map((target) => <div key={target.id} className={'target-row ' + (target.id === selected?.id ? 'is-selected ' : '') + (target.proxy === 'LEAK' ? 'has-leak' : '')} role="button" tabIndex={0} onClick={() => onSelect(target)} onKeyDown={(event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); onSelect(target) } }}><div className="target-cell target-name"><div className={'target-avatar ' + (target.proxy === 'OK' ? 'healthy' : target.proxy === 'FAIL' || target.proxy === 'LEAK' ? 'attention' : 'muted')}>{target.name.slice(0, 2).toUpperCase()}</div><div><strong>{target.name}</strong><span>{target.destination}</span></div></div><div className="target-cell connection-cell"><div><span className="cell-label">{t('SSH')}</span><StatusBadge status={target.ssh} compact /></div><span className="port-label">:{target.sshPort}</span></div><div className="target-cell task-cell"><TaskBadge state={target.taskState} /><span>{target.task}</span></div><div className="target-cell"><StatusBadge status={target.proxy} /></div><div className="target-cell access-cell"><Toggle enabled={target.enabled} disabled={loading || busy} onChange={() => onToggle(target)} /><span>{target.enabled ? t('Enabled') : t('Disabled')}</span></div><div className="row-more"><button className="icon-button" onClick={(event) => { event.stopPropagation(); onSelect(target) }} aria-label={t('Open {name}', { name: target.name })}><Icon name="more" size={18} /></button></div></div>)}</div>}</div></section>
}

function ActivityPanel({ logs, loading }: { logs: LogEntry[]; loading: boolean }) {
  const { t } = useI18n()
  return <article className="activity-card activity-card-full"><div className="section-heading compact-heading"><div><span className="eyebrow">{t('RECENT ACTIVITY')}</span><h2>{t('All activity')}</h2></div></div>{logs.length === 0 ? loading ? <LoadingState /> : <div className="activity-empty">{t('No activity yet')}</div> : <div className="activity-list">{logs.map((entry) => <div className="activity-item" key={entry.id}><div className={'activity-marker ' + (entry.tone ?? 'default')}><Icon name={entry.tone === 'warning' ? 'warning' : entry.tone === 'success' ? 'check' : 'terminal'} size={14} /></div><div><p>{t(entry.messageKey ?? entry.message, entry.messageValues)}</p><span>{entry.time}</span></div></div>)}</div>}</article>
}

interface TargetDetailsProps {
  selected?: Target
  actionBusy: boolean
  primaryIcon: IconName
  primaryAction: string
  onPrimary: () => void
  onEdit: () => void
  onPrepareSsh: () => void
  onRemove: () => void
  onAdd: () => void
  loading: boolean
  onClose: () => void
}

function TargetDetails({ selected, actionBusy, primaryIcon, primaryAction, onPrimary, onEdit, onPrepareSsh, onRemove, onAdd, loading, onClose }: TargetDetailsProps) {
  const { t } = useI18n()
  return <aside className="details-card">{selected ? <><div className="details-header"><div><span className="eyebrow">{t('SELECTED TARGET')}</span><h2>{selected.name}</h2></div><button className="icon-button" onClick={onClose} aria-label={t('Close target details')}><span>×</span></button></div><div className="details-status"><div className={'large-status ' + (selected.proxy === 'OK' ? 'good' : selected.proxy === 'FAIL' || selected.proxy === 'LEAK' ? 'bad' : 'muted')}><span className="status-dot" /><strong>{t(statusLabel(selected.proxy))}</strong></div><span>{t('Checked {duration}', { duration: selected.durationMs ? String(selected.durationMs) + ' ms' : t('recently') })}</span></div><dl className="details-list"><div><dt>{t('Destination')}</dt><dd>{selected.destination}</dd></div><div><dt>{t('Remote proxy')}</dt><dd>127.0.0.1:{selected.remotePort}</dd></div><div><dt>{t('Scheduled task')}</dt><dd>{selected.task}</dd></div><div><dt>{t('SSH identity')}</dt><dd>{selected.identityFile}</dd></div></dl><div className="details-actions"><button className="button primary full" onClick={onPrimary} disabled={actionBusy}><Icon name={primaryIcon} size={16} />{actionBusy ? t('Working…') : t(primaryAction)}</button><button className="button ghost full" onClick={onEdit} disabled={actionBusy}><Icon name="edit" size={16} />{t('Edit details')}</button></div><div className="details-secondary"><button onClick={onPrepareSsh} disabled={actionBusy}><Icon name="key" size={15} />{t('Configure SSH login')}</button><button className="danger-link" onClick={onRemove} disabled={actionBusy}><Icon name="trash" size={15} />{t('Remove target')}</button></div></> : loading ? <LoadingState /> : <EmptyState onAdd={onAdd} />}</aside>
}

interface RemoveTargetDialogProps {
  target: Target
  busy: boolean
  onCancel: () => void
  onConfirm: (deleteIdentityFile: boolean) => void
}

function RemoveTargetDialog({ target, busy, onCancel, onConfirm }: RemoveTargetDialogProps) {
  const { t } = useI18n()
  const [deleteIdentityFile, setDeleteIdentityFile] = useState(target.identityManaged)
  const submit = (event: FormEvent) => {
    event.preventDefault()
    if (!busy) onConfirm(deleteIdentityFile)
  }
  return <div className="modal-backdrop" onMouseDown={(event) => { if (event.target === event.currentTarget && !busy) onCancel() }}>
    <form className="modal-card removal-card" onSubmit={submit}>
      <div className="modal-header"><div><span className="eyebrow">{t('REMOVE TARGET')}</span><h2>{t('Remove {name}?', { name: target.name })}</h2><p>{t('This will stop the Windows tunnel and remove the Linux integration and public key.')}</p></div><button type="button" className="icon-button" onClick={onCancel} disabled={busy} aria-label={t('Close')}><span>×</span></button></div>
      {target.identityManaged
        ? <label className="removal-option"><input type="checkbox" checked={deleteIdentityFile} onChange={(event) => setDeleteIdentityFile(event.target.checked)} disabled={busy} /><span><strong>{t('Also delete this target’s private key')}</strong><small>{t('The key is unique to this target and cannot be recovered after deletion.')}</small></span></label>
        : <div className="notice"><Icon name="key" size={17} /><span>{t('This target uses an existing private key. The key file will be kept.')}</span></div>}
      <div className="removal-scope"><Icon name="warning" size={17} /><span>{t('Only this target’s Windows task, remote integration, and public key will be removed; the dedicated key file is removed only if you select it. The Linux account itself will not be deleted.')}</span></div>
      <div className="modal-actions"><button type="button" className="button ghost" onClick={onCancel} disabled={busy}>{t('Cancel')}</button><button type="submit" className="button danger-button" disabled={busy}>{busy ? t('Removing…') : deleteIdentityFile && target.identityManaged ? t('Remove target and private key') : t('Remove target only')}<Icon name="trash" size={16} /></button></div>
    </form>
  </div>
}

function SettingsPanel() {
  const { t } = useI18n()
  return <section className="settings-grid"><article className="settings-card"><div className="settings-card-copy"><div className="settings-icon"><Icon name="settings" size={19} /></div><div><span className="eyebrow">{t('SYSTEM SETTINGS')}</span><h2>{t('Interface language')}</h2><p>{t('Choose between English and Chinese. Your choice is saved on this PC.')}</p></div></div><LanguageSwitch /></article><article className="settings-card"><div className="settings-card-copy"><div className="settings-icon secure"><Icon name="lock" size={19} /></div><div><span className="eyebrow">{t('LOCAL PROXY')}</span><h2>{t('Local configuration')}</h2><p>{t('Configuration and credentials remain on this PC.')}</p></div></div></article></section>
}

function App() {
  const { t, locale, setLocale } = useI18n()
  const [manager, setManager] = useState<ManagerState>(() => demoPreview ? demoState : emptyState)
  const [selectedId, setSelectedId] = useState(() => demoPreview ? 'tgt-demo-tokyo' : '')
  const [search, setSearch] = useState('')
  const [loading, setLoading] = useState(!demoPreview)
  const [actionBusy, setActionBusy] = useState(false)
  const [error, setError] = useState('')
  const [modalTarget, setModalTarget] = useState<Target | 'new' | undefined>()
  const [wizardStage, setWizardStage] = useState<TargetWizardStage>('details')
  const [wizardMessage, setWizardMessage] = useState('')
  const [wizardError, setWizardError] = useState(false)
  const [activeNav, setActiveNav] = useState('Overview')
  const [detailsOpen, setDetailsOpen] = useState(false)
  const [removeTarget, setRemoveTarget] = useState<Target>()
  const [bridgeStatus, setBridgeStatus] = useState<BridgeStatus>(demoPreview ? 'connected' : 'checking')
  const loadRequestRef = useRef(0)

  useEffect(() => {
    if (modalTarget === 'new') {
      setWizardStage('details')
      setWizardMessage('')
      setWizardError(false)
    }
  }, [modalTarget])

  const load = async () => {
    if (demoPreview) return
    const requestId = ++loadRequestRef.current
    setLoading(true)
    setError('')
    try {
      const next = normalizeState(await fetchState())
      if (requestId !== loadRequestRef.current) return
      setManager(next)
      setBridgeStatus('connected')
      if (next.targets.length && !next.targets.some((target) => target.id === selectedId)) setSelectedId(next.targets[0].id)
      if (!next.targets.length) {
        setSelectedId('')
        setDetailsOpen(false)
      }
    } catch (cause) {
      if (requestId !== loadRequestRef.current) return
      setBridgeStatus('offline')
      setError(cause instanceof Error ? cause.message : t('Unable to reach the manager bridge.'))
    } finally {
      if (requestId === loadRequestRef.current) setLoading(false)
    }
  }

  useEffect(() => { if (!demoPreview) void load() }, [])

  useEffect(() => {
    if (demoPreview) return
    const timer = window.setInterval(() => {
      void sendHeartbeat()
        .then(() => setBridgeStatus('connected'))
        .catch(() => setBridgeStatus('offline'))
    }, 10000)
    return () => window.clearInterval(timer)
  }, [])

  const selected = manager.targets.find((target) => target.id === selectedId) ?? manager.targets[0]
  const filteredTargets = useMemo(() => manager.targets.filter((target) => (target.name + ' ' + target.host + ' ' + target.user).toLowerCase().includes(search.toLowerCase())), [manager.targets, search])
  const checkedLabel = manager.checkedAt ? formatTime(manager.checkedAt) : t('Not checked yet')
  const stats = useMemo(() => ({
    total: manager.targets.length,
    active: manager.targets.filter((target) => target.enabled && target.taskState === 'Running').length,
    healthy: manager.targets.filter((target) => target.proxy === 'OK').length,
    attention: manager.targets.filter((target) => !['OK', 'BLOCKED', 'DISABLED'].includes(target.proxy)).length,
  }), [manager.targets])

  const selectTarget = (target: Target) => {
    setSelectedId(target.id)
    setDetailsOpen(true)
  }
  const navigate = (view: string) => {
    setActiveNav(view)
    if (view !== 'Targets') setDetailsOpen(false)
  }
  const sessionLabel = manager.mode === 'demo'
    ? t('Preview mode')
    : bridgeStatus === 'connected'
      ? t('Live session')
      : bridgeStatus === 'checking'
        ? t('Connecting…')
        : t('Manager unavailable')
  const connectionLabel = manager.mode === 'demo'
    ? t('Design preview')
    : bridgeStatus === 'connected'
      ? t('Connected to manager')
      : bridgeStatus === 'checking'
        ? t('Connecting to manager')
        : t('Manager unavailable')

  const addLog = (message: string, tone: LogEntry['tone'] = 'default', values?: Record<string, string | number>) => setManager((current) => ({ ...current, logs: [{ id: String(Date.now()), time: now(), message, messageKey: message, messageValues: values, tone }, ...current.logs].slice(0, 12) }))

  const mutate = async (command: string, target?: TargetForm & { name: string }, options: ManagerActionOptions = {}) => {
    if (actionBusy) return
    setActionBusy(true)
    setError('')
    try {
      if (manager.mode === 'demo') {
        if (command === 'add' && target) {
          const next: Target = { ...target, id: target.id, destination: target.user + '@' + target.host, task: target.taskName || 'ClashProxyTo-' + target.name, taskState: 'Running', enabled: true, ssh: 'OK', proxy: 'OK', remotePort: target.remoteProxyPort, identityManaged: !target.identityFile, identityFile: target.identityFile || '%LOCALAPPDATA%\\ClashSshProxy\\keys\\' + target.id + '.ed25519', noProxyExtra: target.noProxyExtra.split(',').map((item) => item.trim()).filter(Boolean), durationMs: 64 }
          setManager((current) => ({ ...current, targets: [...current.targets, next] }))
          setSelectedId(next.id); addLog('Added {name} and started its proxy tunnel.', 'success', { name: next.name })
        } else if ((command === 'enable' || command === 'disable') && target) {
          setManager((current) => ({ ...current, targets: current.targets.map((item) => item.id === target.id ? { ...item, enabled: command === 'enable', taskState: command === 'enable' ? 'Running' : 'Disabled', proxy: command === 'enable' ? 'OK' : 'BLOCKED' } : item) }))
          addLog(command === 'enable' ? 'Enabled proxy access for {name}.' : 'Disabled proxy access for {name}.', 'success', { name: target.name })
        } else if (command === 'remove' && target) {
          setManager((current) => ({ ...current, targets: current.targets.filter((item) => item.id !== target.id) }))
          addLog('Removed {name}.', 'warning', { name: target.name })
        } else if (command === 'update' && target) {
          setManager((current) => ({ ...current, targets: current.targets.map((item) => item.id === target.id ? { ...item, host: target.host, user: target.user, destination: target.user + '@' + target.host, sshPort: target.sshPort, remotePort: target.remoteProxyPort, task: target.taskName || item.task, identityFile: target.identityFile, noProxyExtra: target.noProxyExtra.split(',').map((item) => item.trim()).filter(Boolean) } : item) }))
          addLog('Updated {name}.', 'success', { name: target.name })
        } else if (command === 'status') {
          addLog('Health check completed.', 'default')
        }
      } else {
        const result = await runAction(command, target, options)
        if (!result.ok) throw new Error(result.message ?? t('The operation failed.'))
        await load()
      }
      setModalTarget(undefined)
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : t('The operation failed.'))
    } finally {
      setActionBusy(false)
    }
  }

  const getActionError = (cause: unknown, fallback: string) => cause instanceof Error ? cause.message : fallback

  const installNewTarget = async (form: TargetForm) => {
    setWizardStage('installing')
    setWizardMessage('')
    setWizardError(false)
    setActionBusy(true)
    setError('')
    try {
      const result = await runAction('add', form)
      if (!result.ok) throw new Error(result.message ?? t('The operation failed.'))
      await load()
      setModalTarget(undefined)
    } catch (cause) {
      setWizardMessage(getActionError(cause, t('The operation failed.')))
      setWizardError(true)
    } finally {
      setActionBusy(false)
    }
  }

  const checkNewTargetSsh = async (form: TargetForm, verifying = false) => {
    setWizardStage(verifying ? 'verifying-ssh' : 'checking-ssh')
    setWizardMessage('')
    setWizardError(false)
    setActionBusy(true)
    setError('')
    try {
      const result = await runAction('prepare-ssh', form)
      if (!result.ok) throw new Error(result.message ?? t('Unable to prepare SSH access.'))
      if (result.ready) {
        await installNewTarget(form)
        return
      }
      setWizardStage(verifying ? 'verifying-ssh' : 'ssh-auth')
      setWizardMessage(verifying ? t('SSH key is still not ready. Finish the setup window and try again.') : t('SSH key login needs one-time setup.'))
    } catch (cause) {
      setWizardMessage(getActionError(cause, t('Unable to prepare SSH access.')))
      setWizardError(true)
    } finally {
      setActionBusy(false)
    }
  }

  const startSshBootstrap = async (form: TargetForm) => {
    setActionBusy(true)
    setWizardMessage('')
    setWizardError(false)
    setError('')
    try {
      const result = await runAction('bootstrap-key', form)
      if (!result.ok) throw new Error(result.message ?? t('Unable to open SSH setup.'))
      setWizardStage('verifying-ssh')
      setWizardMessage(t('Finish the SSH setup window, then verify the connection here.'))
    } catch (cause) {
      setWizardMessage(getActionError(cause, t('Unable to open SSH setup.')))
      setWizardError(true)
    } finally {
      setActionBusy(false)
    }
  }

  const backToTargetDetails = () => {
    setWizardStage('details')
    setWizardMessage('')
    setWizardError(false)
  }

  const toggleTarget = (target: Target) => void mutate(target.enabled ? 'disable' : 'enable', { ...targetToForm(target), name: target.name })
  const primaryAction = selected ? selected.taskState === 'Missing' ? 'Edit / update' : selected.enabled && !['Ready', 'Disabled'].includes(selected.taskState) ? 'Disable proxy' : 'Enable proxy' : 'Select a target'
  const primaryIcon: IconName = primaryAction === 'Disable proxy' ? 'lock' : primaryAction === 'Edit / update' ? 'edit' : 'arrow'

  const handlePrimary = () => {
    if (!selected) return
    if (selected.taskState === 'Missing') setModalTarget(selected)
    else toggleTarget(selected)
  }

  const submitTarget = (form: TargetForm) => {
    const target = { ...form, name: modalTarget && modalTarget !== 'new' ? modalTarget.name : form.name }
    if (modalTarget === 'new') {
      if (manager.mode === 'demo') void mutate('add', target)
      else void checkNewTargetSsh(target)
      return
    }
    void mutate('update', target)
  }

  const handleInsight = () => {
    if (stats.attention) {
      setSelectedId(manager.targets.find((target) => !['OK', 'BLOCKED', 'DISABLED'].includes(target.proxy))?.id ?? selectedId)
      setDetailsOpen(true)
      navigate('Targets')
    } else {
      navigate('Activity')
    }
  }

  const prepareSsh = () => {
    if (selected) void mutate('prepare-ssh', { ...targetToForm(selected), name: selected.name })
  }

  const removeSelected = () => {
    if (selected && !actionBusy) {
      setRemoveTarget(selected)
    }
  }

  const confirmRemove = (deleteIdentityFile: boolean) => {
    if (!removeTarget) return
    const target = removeTarget
    setRemoveTarget(undefined)
    setDetailsOpen(false)
    void mutate('remove', { ...targetToForm(target), name: target.name }, { deleteIdentityFile })
  }
  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="brand"><div className="brand-mark"><Icon name="pulse" size={21} /></div><div><strong>{t('Proxy Manager')}</strong><span>{t('SSH access control')}</span></div></div>
        <div className="sidebar-section"><span className="sidebar-label">{t('Workspace')}</span><nav>
           {([['Overview', 'overview'], ['Targets', 'servers'], ['Activity', 'activity']] as [string, IconName][]).map(([label, icon]) => <button key={label} className={'nav-item ' + (activeNav === label ? 'active' : '')} onClick={() => navigate(label)}><Icon name={icon} size={18} /><span>{t(label)}</span>{label === 'Targets' && <span className="nav-count">{stats.total}</span>}</button>)}
        </nav></div>
        <div className="sidebar-section sidebar-bottom"><span className="sidebar-label">{t('System')}</span><button className={'nav-item ' + (activeNav === 'Settings' ? 'active' : '')} onClick={() => setActiveNav('Settings')}><Icon name="settings" size={18} /><span>{t('Settings')}</span></button><div className="secure-card"><div className="secure-icon"><Icon name="lock" size={16} /></div><div><strong>{t('Local only')}</strong><span>{t('Credentials stay on this PC.')}</span></div></div></div>
         <div className="sidebar-footer"><span className={'connection-dot ' + (manager.mode === 'demo' ? 'demo' : bridgeStatus)} />{connectionLabel}<span className="version">v1.0</span></div>
      </aside>
      <main className="main-shell">
         <header className="topbar"><div className="breadcrumbs"><span>{t('Workspace')}</span><Icon name="chevron" size={14} /><strong>{t(activeNav)}</strong></div><div className="topbar-actions"><LanguageSwitch /><span className={'mode-pill ' + (manager.mode === 'demo' ? 'demo' : 'live ' + bridgeStatus)}><span className="status-dot" />{sessionLabel}</span><button className="avatar" aria-label={t('Account')}>PM</button></div></header>
        <div className="content">
          {activeNav === 'Overview' && <>
            <section className="page-heading"><div><span className="eyebrow">{t('CONTROL CENTER')}</span><h1>{t('Proxy control center')}</h1><p>{t('See every Linux tunnel at a glance and keep your proxy access under control.')}</p></div><div className="heading-actions">{loading && !manager.checkedAt && <span className="loading-indicator" role="status"><Icon name="refresh" size={14} />{t('Loading live manager data…')}</span>}<button className="button ghost" onClick={() => void load()} disabled={loading || actionBusy}><Icon name="refresh" size={16} />{loading ? t('Refreshing…') : t('Refresh status')}</button><button className="button primary" onClick={() => setModalTarget('new')} disabled={loading || actionBusy}><Icon name="plus" size={16} />{t('Add target')}</button></div></section>
            {error && <ErrorBanner message={error} note={manager.checkedAt ? t('Showing the last successful snapshot.') : t('No live data loaded yet.')} onRetry={() => void load()} onDismiss={() => setError('')} />}
            <section className="stats-grid"><StatCard label={t('Managed targets')} value={stats.total} hint={t('Across this workspace')} icon="servers" tone="blue" /><StatCard label={t('Active tunnels')} value={stats.active} hint={stats.total ? t('{percent}% of targets', { percent: Math.round((stats.active / stats.total) * 100) }) : t('Nothing running')} icon="activity" tone="green" /><StatCard label={t('Healthy now')} value={stats.healthy} hint={stats.healthy ? t('Proxy probes passing') : t('Run a health check')} icon="check" tone="violet" /><StatCard label={t('Needs attention')} value={stats.attention} hint={stats.attention ? t('Review before relying on it') : t('Everything looks good')} icon="warning" tone="amber" /></section>
            <section className="overview-grid"><article className={'local-card ' + (manager.localProxy.up ? 'up' : 'down')}><div className="card-topline"><div className="local-title"><div className="local-icon"><Icon name="pulse" size={20} /></div><div><span className="eyebrow">{t('LOCAL PROXY')}</span><h2>{t('Clash endpoint')}</h2></div></div><span className={'availability ' + (manager.localProxy.up ? 'up' : 'down')}><span className="status-dot" />{manager.localProxy.up ? t('Operational') : t('Offline')}</span></div><div className="endpoint"><strong>{manager.localProxy.host}:{manager.localProxy.port}</strong><span>{t('Requests from enabled tunnels are routed through this local listener.')}</span></div><div className="local-footer"><div><span className="metric-label">{t('Last checked')}</span><strong>{checkedLabel}</strong></div><div><span className="metric-label">{t('Transport')}</span><strong>HTTP / SOCKS5</strong></div><button className="text-button" onClick={() => void load()} disabled={loading || actionBusy}>{loading ? t('Refreshing…') : t('Run check')} <Icon name="arrow" size={15} /></button></div></article><article className="insight-card"><div className="card-topline"><div><span className="eyebrow">{t('QUICK INSIGHT')}</span><h2>{stats.attention ? t('One tunnel needs a look') : t('All systems look good')}</h2></div><div className={'insight-icon ' + (stats.attention ? 'warning' : 'good')}><Icon name={stats.attention ? 'warning' : 'check'} size={19} /></div></div><p>{stats.attention ? t('A failed proxy probe is isolated from the healthy targets. Open the target details to inspect or restart it.') : t('Your enabled targets are running and proxy probes are passing.')}</p><div className="insight-link" onClick={handleInsight}>{stats.attention ? t('Review attention items') : t('View activity')} <Icon name="arrow" size={15} /></div></article></section>
          </>}
          {activeNav === 'Targets' && <>
            <section className="page-heading"><div><span className="eyebrow">{t('MANAGED TARGETS')}</span><h1>{t('Your Linux destinations')}</h1><p>{t('Add, inspect, and control every SSH proxy tunnel from one place.')}</p></div><div className="heading-actions"><button className="button ghost" onClick={() => void load()} disabled={loading || actionBusy}><Icon name="refresh" size={16} />{loading ? t('Refreshing…') : t('Refresh status')}</button><button className="button primary" onClick={() => setModalTarget('new')} disabled={loading || actionBusy}><Icon name="plus" size={16} />{t('Add target')}</button></div></section>
            {error && <ErrorBanner message={error} note={manager.checkedAt ? t('Showing the last successful snapshot.') : t('No live data loaded yet.')} onRetry={() => void load()} onDismiss={() => setError('')} />}
            <TargetTable targets={filteredTargets} selected={selected} search={search} loading={loading} busy={actionBusy} onSearch={setSearch} onHealthCheck={() => void mutate('status')} onAdd={() => setModalTarget('new')} onSelect={selectTarget} onToggle={toggleTarget} />
            {detailsOpen && selected && <div className="details-drawer-layer"><button type="button" className="details-drawer-scrim" onClick={() => setDetailsOpen(false)} aria-label={t('Close target details')} /><aside className="details-drawer"><TargetDetails selected={selected} actionBusy={actionBusy} primaryIcon={primaryIcon} primaryAction={primaryAction} onPrimary={handlePrimary} onEdit={() => { setDetailsOpen(false); setModalTarget(selected) }} onPrepareSsh={prepareSsh} onRemove={removeSelected} onAdd={() => setModalTarget('new')} loading={loading} onClose={() => setDetailsOpen(false)} /></aside></div>}
          </>}
          {activeNav === 'Activity' && <>
            <section className="page-heading"><div><span className="eyebrow">{t('RECENT ACTIVITY')}</span><h1>{t('Activity log')}</h1><p>{t('Review manager events, health checks, and tunnel changes.')}</p></div><div className="heading-actions"><button className="button ghost" onClick={() => void load()} disabled={loading || actionBusy}><Icon name="refresh" size={16} />{loading ? t('Refreshing…') : t('Refresh status')}</button></div></section>
            {error && <ErrorBanner message={error} note={manager.checkedAt ? t('Showing the last successful snapshot.') : t('No live data loaded yet.')} onRetry={() => void load()} onDismiss={() => setError('')} />}
            <ActivityPanel logs={manager.logs} loading={loading} />
          </>}
          {activeNav === 'Settings' && <>
            <section className="page-heading"><div><span className="eyebrow">{t('SYSTEM SETTINGS')}</span><h1>{t('Settings')}</h1><p>{t('Local manager preferences and connection details.')}</p></div></section>
            <SettingsPanel />
          </>}
        </div>
         <footer className="app-footer"><span><span className={'connection-dot ' + (manager.mode === 'demo' ? 'demo' : bridgeStatus)} />{connectionLabel}</span><span>{t('Config: {path}', { path: manager.configPath })}</span><span>{t('Updated {time}', { time: checkedLabel })}</span></footer>
      </main>
      {modalTarget && <TargetModal
        target={modalTarget === 'new' ? undefined : modalTarget}
        onClose={() => setModalTarget(undefined)}
        onSubmit={submitTarget}
        busy={actionBusy}
        wizardStage={wizardStage}
        wizardMessage={wizardMessage}
        wizardError={wizardError}
        onBootstrapSsh={startSshBootstrap}
        onVerifySsh={(form) => void checkNewTargetSsh(form, true)}
        onInstallTarget={(form) => void installNewTarget(form)}
        onBackToDetails={backToTargetDetails}
      />}
      {removeTarget && <RemoveTargetDialog target={removeTarget} busy={actionBusy} onCancel={() => setRemoveTarget(undefined)} onConfirm={confirmRemove} />}
    </div>
  )
}

export default App
