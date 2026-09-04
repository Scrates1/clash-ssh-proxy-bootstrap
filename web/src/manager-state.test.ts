import { describe, expect, it } from 'vitest'
import { newTargetId, normalizeState, targetToForm } from './manager-state'
import type { ManagerState, Target } from './types'

describe('normalizeState', () => {
  it('normalizes PowerShell-style target properties', () => {
    const raw = {
      mode: 'live',
      configPath: 'config.json',
      localProxy: { host: '127.0.0.1', port: 7897, up: true },
      checkedAt: '2026-09-04T00:00:00Z',
      logs: [],
      targets: [{
        Id: 'tgt-test', Name: 'edge', Host: 'linux.example.com', User: 'deploy',
        TaskName: 'ClashProxyTo-edge', TaskState: 'Running', Enabled: true,
        SSH: 'OK', Proxy: 'OK', RemotePort: 17897, SshPort: 2222,
        IdentityFile: 'id_ed25519', IdentityManaged: true,
        NoProxyExtra: ['internal.example.com'], DurationMs: 42,
      }],
    } as unknown as ManagerState

    const state = normalizeState(raw)
    expect(state.targets[0]).toMatchObject({
      id: 'tgt-test',
      destination: 'deploy@linux.example.com',
      task: 'ClashProxyTo-edge',
      taskState: 'Running',
      enabled: true,
      remotePort: 17897,
      sshPort: 2222,
      identityManaged: true,
      noProxyExtra: ['internal.example.com'],
    })
  })

  it('rejects malformed target containers and applies safe defaults', () => {
    const state = normalizeState({ targets: [null, 'bad', []] } as unknown as ManagerState)
    expect(state.mode).toBe('live')
    expect(state.localProxy).toEqual({ host: '127.0.0.1', port: 7897, up: false })
    expect(state.targets).toEqual([])
  })
})

describe('target forms', () => {
  it('maps a target without losing editable values', () => {
    const target = {
      id: 'tgt-existing', name: 'edge', host: 'host', user: 'user', destination: 'user@host',
      task: 'Task', taskState: 'Disabled', enabled: false, ssh: 'UNKNOWN', proxy: 'BLOCKED',
      remotePort: 18000, sshPort: 2200, identityFile: 'identity', identityManaged: false,
      noProxyExtra: ['one.example', 'two.example'],
    } satisfies Target
    expect(targetToForm(target)).toEqual({
      id: 'tgt-existing', name: 'edge', host: 'host', user: 'user', sshPort: 2200,
      identityFile: 'identity', remoteProxyPort: 18000, taskName: 'Task',
      noProxyExtra: 'one.example, two.example',
    })
  })

  it('creates a schema-compatible id for a new target', () => {
    expect(newTargetId()).toMatch(/^tgt-[A-Za-z0-9][A-Za-z0-9._-]*$/)
  })
})
