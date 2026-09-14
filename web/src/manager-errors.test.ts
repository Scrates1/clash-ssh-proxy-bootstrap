import { expect, it } from 'vitest'
import { formatManagerError, ManagerActionError } from './manager-errors'

const translate = (key: string, values?: Record<string, string | number>) =>
  key.replace(/\{(\w+)\}/g, (_, name: string) => String(values?.[name] ?? `{${name}}`))

it('turns a structured port error into a concrete recovery action', () => {
  const error = new ManagerActionError('raw error', 'REMOTE_PROXY_PORT_IN_USE', { host: 'linux.example.com', port: 18000 })
  expect(formatManagerError(error, 'fallback', translate)).toContain('Port 18000 on linux.example.com is already listening')
  expect(formatManagerError(error, 'fallback', translate)).toContain('Edit the connection details')
})

it('preserves unknown backend errors instead of hiding them behind a generic message', () => {
  expect(formatManagerError(new ManagerActionError('Host key verification failed', 'NEW_CODE'), 'fallback', translate)).toBe('Host key verification failed')
  expect(formatManagerError(null, 'fallback', translate)).toBe('fallback')
})
