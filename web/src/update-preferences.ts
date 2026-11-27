import type { UpdateStatus } from './types'

export const UPDATE_PREFS_STORAGE_KEY = 'clash-ssh-proxy-update-prefs'
export const DEFAULT_REMIND_LATER_MS = 24 * 60 * 60 * 1000

export interface UpdatePreferences {
  autoCheck: boolean
  skippedVersion: string
  snoozedUntil: number
}

export const defaultUpdatePreferences: UpdatePreferences = {
  autoCheck: true,
  skippedVersion: '',
  snoozedUntil: 0,
}

export function readUpdatePreferences(): UpdatePreferences {
  if (typeof window === 'undefined') return defaultUpdatePreferences
  try {
    const raw = window.localStorage.getItem(UPDATE_PREFS_STORAGE_KEY)
    if (!raw) return defaultUpdatePreferences
    const parsed = JSON.parse(raw) as Partial<UpdatePreferences>
    return {
      autoCheck: typeof parsed.autoCheck === 'boolean' ? parsed.autoCheck : true,
      skippedVersion: typeof parsed.skippedVersion === 'string' ? parsed.skippedVersion : '',
      snoozedUntil: typeof parsed.snoozedUntil === 'number' && Number.isFinite(parsed.snoozedUntil) ? parsed.snoozedUntil : 0,
    }
  } catch {
    return defaultUpdatePreferences
  }
}

export function saveUpdatePreferences(next: UpdatePreferences): void {
  if (typeof window === 'undefined') return
  try {
    window.localStorage.setItem(UPDATE_PREFS_STORAGE_KEY, JSON.stringify(next))
  } catch {
    // Restricted browser contexts keep preferences in memory for the current tab.
  }
}

export function shouldShowUpdateBanner(
  update: UpdateStatus | undefined,
  prefs: UpdatePreferences,
  nowMs = Date.now(),
): boolean {
  if (!update || !update.updateAvailable || !prefs.autoCheck) return false
  if (prefs.skippedVersion && prefs.skippedVersion === update.latestVersion) return false
  if (prefs.snoozedUntil > nowMs) return false
  return true
}

export function shouldShowSidebarUpdateBadge(
  update: UpdateStatus | undefined,
  prefs: UpdatePreferences,
): boolean {
  if (!update || !update.updateAvailable || !prefs.autoCheck) return false
  if (prefs.skippedVersion && prefs.skippedVersion === update.latestVersion) return false
  return true
}
