export interface ManagerSessionLocation {
  token: string
  sanitizedPath: string
}

export const MANAGER_SESSION_STORAGE_KEY = 'clash-ssh-proxy-manager.session-token'
export const MANAGER_SESSION_HISTORY_KEY = 'clashSshProxyManagerSessionToken'

export function parseManagerSessionLocation(href: string): ManagerSessionLocation {
  const url = new URL(href)
  const rawFragment = url.hash.startsWith('#') ? url.hash.slice(1) : url.hash
  const fragmentHasToken = /(^|&)token=/.test(rawFragment)
  const fragment = fragmentHasToken ? new URLSearchParams(rawFragment) : undefined
  const token = fragment?.get('token') ?? url.searchParams.get('token') ?? ''

  fragment?.delete('token')
  url.searchParams.delete('token')
  const sanitizedFragment = fragment ? fragment.toString() : rawFragment
  return {
    token,
    sanitizedPath: `${url.pathname}${url.search}${sanitizedFragment ? `#${sanitizedFragment}` : ''}`,
  }
}

export function consumeBrowserManagerSession(): string {
  if (typeof window === 'undefined') return ''
  const session = parseManagerSessionLocation(window.location.href)
  if (session.token) {
    let storedInSession = false
    try {
      window.sessionStorage.setItem(MANAGER_SESSION_STORAGE_KEY, session.token)
      storedInSession = true
    } catch {
      // History state keeps reloads working when session storage is restricted.
    }
    try {
      const currentState = window.history.state
      const nextState = currentState !== null && typeof currentState === 'object' && !Array.isArray(currentState)
        ? { ...currentState }
        : {}
      if (storedInSession) {
        delete nextState[MANAGER_SESSION_HISTORY_KEY]
      } else {
        nextState[MANAGER_SESSION_HISTORY_KEY] = session.token
      }
      window.history.replaceState(nextState, '', session.sanitizedPath)
    } catch {
      // Keeping the source URL is safer than breaking reloads if history is restricted.
    }
    return session.token
  }
  try {
    const storedToken = window.sessionStorage.getItem(MANAGER_SESSION_STORAGE_KEY)
    if (storedToken) return storedToken
  } catch {
    // Fall through to the current history entry.
  }
  try {
    const historyState = window.history.state
    if (historyState !== null && typeof historyState === 'object' && !Array.isArray(historyState)) {
      const historyToken = (historyState as Record<string, unknown>)[MANAGER_SESSION_HISTORY_KEY]
      if (typeof historyToken === 'string') return historyToken
    }
  } catch {
    // A restricted browser context will simply start without a live session.
  }
  return ''
}
