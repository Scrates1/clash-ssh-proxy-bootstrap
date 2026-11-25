import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { fetchState, hasActiveManagerRequest, runAction, sendHeartbeat } from './api'

beforeEach(() => {
  vi.useFakeTimers()
  vi.stubGlobal('window', { setTimeout: globalThis.setTimeout, clearTimeout: globalThis.clearTimeout })
})

afterEach(() => {
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

it('turns a browser transport failure into a manager connection error', async () => {
  vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new TypeError('Failed to fetch')))
  await expect(fetchState()).rejects.toMatchObject({ code: 'MANAGER_UNREACHABLE' })
  expect(vi.getTimerCount()).toBe(0)
})

it('times out a response whose headers arrive but whose body never finishes', async () => {
  vi.stubGlobal('fetch', vi.fn(async (_path: string, init: RequestInit) => ({
    ok: true,
    json: () => new Promise((_resolve, reject) => {
      init.signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')))
    }),
  })))
  const failure = expect(fetchState()).rejects.toMatchObject({ code: 'MANAGER_TIMEOUT', details: { seconds: 60 } })
  await vi.advanceTimersByTimeAsync(60000)
  await failure
  expect(vi.getTimerCount()).toBe(0)
})

it('tracks in-flight state and action requests without counting heartbeats', async () => {
  let resolveState: (value: unknown) => void = () => {}
  let resolveHeartbeat: (value: unknown) => void = () => {}
  vi.stubGlobal('fetch', vi.fn((path: string) => new Promise((resolve) => {
    const finish = (payload: unknown) => resolve({ ok: true, json: async () => payload })
    if (path === '/api/heartbeat') resolveHeartbeat = finish
    else resolveState = finish
  })))

  expect(hasActiveManagerRequest()).toBe(false)
  const heartbeatPromise = sendHeartbeat()
  expect(hasActiveManagerRequest()).toBe(false)
  resolveHeartbeat({ ok: true })
  await heartbeatPromise

  const statePromise = fetchState()
  expect(hasActiveManagerRequest()).toBe(true)
  resolveState({ mode: 'live', configPath: '', localProxy: { host: '127.0.0.1', port: 7897, up: true }, targets: [], logs: [], checkedAt: '' })
  await statePromise
  expect(hasActiveManagerRequest()).toBe(false)
})

it('forwards skipRemoteUninstall options on remove actions', async () => {
  const fetchMock = vi.fn().mockResolvedValue({ ok: true, json: async () => ({ ok: true }) })
  vi.stubGlobal('fetch', fetchMock)
  await runAction('remove', {
    id: 'tgt-1', name: 'offline-edge', host: 'linux.example.com', user: 'ubuntu',
    sshPort: 22, identityFile: '', remoteProxyPort: 17897, taskName: 'Task', noProxyExtra: '',
  }, { deleteIdentityFile: false, skipRemoteUninstall: true })

  expect(fetchMock).toHaveBeenCalledTimes(1)
  const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
  expect(JSON.parse(String(init.body))).toMatchObject({
    command: 'remove',
    deleteIdentityFile: false,
    skipRemoteUninstall: true,
  })
})
