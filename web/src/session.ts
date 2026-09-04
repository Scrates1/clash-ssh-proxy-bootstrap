export interface ManagerSessionLocation {
  token: string
  sanitizedPath: string
}

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
    window.history.replaceState(window.history.state, '', session.sanitizedPath)
  }
  return session.token
}
