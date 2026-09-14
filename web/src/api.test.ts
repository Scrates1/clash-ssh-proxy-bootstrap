import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { fetchState } from './api'

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
