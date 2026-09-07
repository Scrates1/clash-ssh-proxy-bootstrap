import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  consumeBrowserManagerSession,
  MANAGER_SESSION_HISTORY_KEY,
  MANAGER_SESSION_STORAGE_KEY,
  parseManagerSessionLocation,
} from './session'

afterEach(() => vi.unstubAllGlobals())

describe('manager session location', () => {
  it('reads the preferred fragment token and removes it from the visible URL', () => {
    expect(parseManagerSessionLocation('http://127.0.0.1:17997/?demo=1#token=secret&panel=targets')).toEqual({
      token: 'secret',
      sanitizedPath: '/?demo=1#panel=targets',
    })
  })

  it('supports and redacts legacy query-string tokens', () => {
    expect(parseManagerSessionLocation('http://127.0.0.1:17997/?token=legacy&demo=1')).toEqual({
      token: 'legacy',
      sanitizedPath: '/?demo=1',
    })
  })

  it('leaves an ordinary URL unchanged', () => {
    expect(parseManagerSessionLocation('http://127.0.0.1:17997/settings#advanced')).toEqual({
      token: '',
      sanitizedPath: '/settings#advanced',
    })
  })

  it('restores a redacted token from session storage after a reload', () => {
    let storedToken: string | null = null
    let historyState: unknown = { preserved: true }
    const location = { href: 'http://127.0.0.1:17997/#token=secret' }
    const replaceState = vi.fn((state: unknown) => { historyState = state })
    vi.stubGlobal('window', {
      location,
      sessionStorage: {
        getItem: vi.fn(() => storedToken),
        setItem: vi.fn((_key: string, value: string) => { storedToken = value }),
      },
      history: {
        get state() { return historyState },
        replaceState,
      },
    })

    expect(consumeBrowserManagerSession()).toBe('secret')
    expect(storedToken).toBe('secret')
    expect(replaceState).toHaveBeenCalledWith({
      preserved: true,
    }, '', '/')

    location.href = 'http://127.0.0.1:17997/'
    replaceState.mockClear()
    expect(consumeBrowserManagerSession()).toBe('secret')
    expect(replaceState).not.toHaveBeenCalled()
  })

  it('uses history state when session storage is unavailable', () => {
    let historyState: unknown = null
    const location = { href: 'http://127.0.0.1:17997/#token=fallback' }
    const replaceState = vi.fn((state: unknown) => { historyState = state })
    vi.stubGlobal('window', {
      location,
      sessionStorage: {
        getItem: vi.fn(() => { throw new Error('storage blocked') }),
        setItem: vi.fn(() => { throw new Error('storage blocked') }),
      },
      history: {
        get state() { return historyState },
        replaceState,
      },
    })

    expect(consumeBrowserManagerSession()).toBe('fallback')
    expect(historyState).toEqual({ [MANAGER_SESSION_HISTORY_KEY]: 'fallback' })

    location.href = 'http://127.0.0.1:17997/'
    expect(consumeBrowserManagerSession()).toBe('fallback')
  })

  it('uses a stable, application-specific storage key', () => {
    expect(MANAGER_SESSION_STORAGE_KEY).toBe('clash-ssh-proxy-manager.session-token')
  })
})
