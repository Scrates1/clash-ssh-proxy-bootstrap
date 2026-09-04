import { describe, expect, it } from 'vitest'
import { parseManagerSessionLocation } from './session'

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
})
