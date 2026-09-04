import type { HealthState, LogEntry, ManagerState, Target, TargetForm, TaskState } from './types'

export const now = () => new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })

export const formatTime = (value: string) => {
  if (!value) return '—'
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? '—' : date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
}

export const demoState: ManagerState = {
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

export const emptyState: ManagerState = {
  mode: 'live',
  configPath: '—',
  localProxy: { host: '127.0.0.1', port: 7897, up: false },
  checkedAt: '',
  targets: [],
  logs: [],
}

export function normalizeState(raw: ManagerState): ManagerState {
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

export function newTargetId() {
  const uuid = typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function'
    ? crypto.randomUUID().replace(/-/g, '')
    : Date.now().toString(16) + Math.random().toString(16).slice(2)
  return 'tgt-' + uuid
}

export function targetToForm(target?: Target): TargetForm {
  return {
    id: target?.id ?? newTargetId(), name: target?.name ?? '', host: target?.host ?? '', user: target?.user ?? '', sshPort: target?.sshPort ?? 22,
    identityFile: target?.identityFile ?? '', remoteProxyPort: target?.remotePort ?? 17897,
    taskName: target?.task ?? '', noProxyExtra: target?.noProxyExtra.join(', ') ?? '',
  }
}
