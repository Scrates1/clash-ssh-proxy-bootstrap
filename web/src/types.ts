export type HealthState =
  | 'OK'
  | 'FAIL'
  | 'CHECKING'
  | 'RECOVERING'
  | 'BLOCKED'
  | 'LEAK'
  | 'UNKNOWN'
  | 'DISABLED'

export type TaskState = 'Running' | 'Ready' | 'Disabled' | 'Queued' | 'Missing' | 'Unknown'

export type ManagerCommand =
  | 'status'
  | 'add'
  | 'update'
  | 'enable'
  | 'disable'
  | 'remove'
  | 'prepare-ssh'
  | 'bootstrap-key'

export interface Target {
  id: string
  name: string
  host: string
  user: string
  destination: string
  task: string
  taskState: TaskState
  enabled: boolean
  ssh: HealthState
  proxy: HealthState
  remotePort: number
  sshPort: number
  identityFile: string
  identityManaged: boolean
  noProxyExtra: string[]
  checkedAt?: string
  durationMs?: number
}

export interface LogEntry {
  id: string
  time: string
  message: string
  messageKey?: string
  messageValues?: Record<string, string | number>
  tone?: 'default' | 'success' | 'warning' | 'error'
}

export interface ManagerState {
  mode: 'live' | 'demo'
  configPath: string
  localProxy: {
    host: string
    port: number
    up: boolean
  }
  targets: Target[]
  logs: LogEntry[]
  checkedAt: string
}

export interface TargetForm {
  id: string
  name: string
  host: string
  user: string
  sshPort: number
  identityFile: string
  remoteProxyPort: number
  taskName: string
  noProxyExtra: string
}
