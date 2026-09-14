import { describe, expect, it } from 'vitest'
import { targetToForm } from './manager-state'
import { findRemotePortConflict, suggestRemoteProxyPort } from './target-validation'
import type { Target } from './types'

const primary: Target = {
  id: 'tgt-primary', name: 'primary', host: 'linux.example.com', user: 'first',
  destination: 'first@linux.example.com', task: 'PrimaryTask', taskState: 'Disabled',
  enabled: false, ssh: 'UNKNOWN', proxy: 'BLOCKED', remotePort: 17897,
  sshPort: 22, identityFile: 'primary-key', identityManaged: true, noProxyExtra: [],
}
const form = { ...targetToForm(), host: 'LINUX.example.com', user: 'second', sshPort: 2222 }

describe('remote proxy port validation', () => {
  it('reserves the host port across accounts, SSH ports, and disabled targets', () => {
    expect(findRemotePortConflict(form, [primary])).toBe(primary)
    expect(suggestRemoteProxyPort(form, [primary])).toBe(17898)
  })

  it('keeps an existing target editable without conflicting with itself', () => {
    expect(findRemotePortConflict(targetToForm(primary), [primary])).toBeUndefined()
  })

  it('allows the same port on another host and skips all reserved ports on this host', () => {
    const targets = [primary, { ...primary, id: 'tgt-next', remotePort: 17898 }]
    expect(findRemotePortConflict({ ...form, host: 'another.example.com' }, targets)).toBeUndefined()
    expect(suggestRemoteProxyPort(form, targets)).toBe(17899)
    expect(findRemotePortConflict({ ...form, remoteProxyPort: 17899 }, targets)).toBeUndefined()
  })

  it('wraps at the maximum port without suggesting a privileged or invalid port', () => {
    const targets = [{ ...primary, remotePort: 65535 }, { ...primary, id: 'tgt-low', remotePort: 1024 }]
    expect(suggestRemoteProxyPort({ ...form, remoteProxyPort: 65535 }, targets)).toBe(1025)
  })
})
