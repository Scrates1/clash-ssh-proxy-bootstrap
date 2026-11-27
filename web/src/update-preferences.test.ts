import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  DEFAULT_REMIND_LATER_MS,
  defaultUpdatePreferences,
  readUpdatePreferences,
  saveUpdatePreferences,
  shouldShowSidebarUpdateBadge,
  shouldShowUpdateBanner,
} from './update-preferences'
import type { UpdateStatus } from './types'

const availableUpdate: UpdateStatus = {
  currentVersion: '1.2.0',
  latestVersion: '1.3.0',
  updateAvailable: true,
  releaseUrl: 'https://github.com/Scrates1/clash-ssh-proxy-bootstrap/releases/tag/v1.3.0',
}

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('update reminder preferences', () => {
  it('shows both banner and sidebar badge when an unskipped update is available', () => {
    expect(shouldShowUpdateBanner(availableUpdate, defaultUpdatePreferences, 1000)).toBe(true)
    expect(shouldShowSidebarUpdateBadge(availableUpdate, defaultUpdatePreferences)).toBe(true)
  })

  it('hides only the banner during a remind-later snooze window and restores it afterward', () => {
    const snoozed = { ...defaultUpdatePreferences, snoozedUntil: 1000 + DEFAULT_REMIND_LATER_MS }
    expect(shouldShowUpdateBanner(availableUpdate, snoozed, 5000)).toBe(false)
    expect(shouldShowSidebarUpdateBadge(availableUpdate, snoozed)).toBe(true)
    expect(shouldShowUpdateBanner(availableUpdate, snoozed, 1000 + DEFAULT_REMIND_LATER_MS)).toBe(true)
  })

  it('suppresses a skipped version while re-enabling notifications for the next release', () => {
    const skipped = { ...defaultUpdatePreferences, skippedVersion: '1.3.0' }
    expect(shouldShowUpdateBanner(availableUpdate, skipped, 1000)).toBe(false)
    expect(shouldShowSidebarUpdateBadge(availableUpdate, skipped)).toBe(false)

    const nextRelease = { ...availableUpdate, latestVersion: '1.4.0' }
    expect(shouldShowUpdateBanner(nextRelease, skipped, 1000)).toBe(true)
    expect(shouldShowSidebarUpdateBadge(nextRelease, skipped)).toBe(true)
  })

  it('turns off all reminders when automatic checks are disabled ("Don’t remind again")', () => {
    const disabled = { ...defaultUpdatePreferences, autoCheck: false }
    expect(shouldShowUpdateBanner(availableUpdate, disabled, 1000)).toBe(false)
    expect(shouldShowSidebarUpdateBadge(availableUpdate, disabled)).toBe(false)
  })

  it('persists and recovers safely from malformed local storage data', () => {
    const store = new Map<string, string>()
    vi.stubGlobal('window', {
      localStorage: {
        getItem: (key: string) => store.get(key) ?? null,
        setItem: (key: string, value: string) => store.set(key, value),
      },
    })

    saveUpdatePreferences({ autoCheck: false, skippedVersion: '1.3.0', snoozedUntil: 9000 })
    expect(readUpdatePreferences()).toEqual({ autoCheck: false, skippedVersion: '1.3.0', snoozedUntil: 9000 })

    store.set('clash-ssh-proxy-update-prefs', '{invalid-json')
    expect(readUpdatePreferences()).toEqual(defaultUpdatePreferences)
  })
})
