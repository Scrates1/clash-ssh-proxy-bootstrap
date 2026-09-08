import type { ManagerCommand, ManagerState, TargetForm } from './types'
import { consumeBrowserManagerSession } from './session'

const sessionToken = consumeBrowserManagerSession()

export const hasManagerSession = Boolean(sessionToken)

const requestTimeout = (path: string) => path === '/api/action' ? 300000 : path === '/api/state' ? 60000 : 15000

export interface ManagerActionResponse {
  ok: boolean
  message?: string
  ready?: boolean
  interactionRequired?: boolean
  identityCreated?: boolean
  publicKeyUpdated?: boolean
  alreadyRunning?: boolean
}

export interface ManagerActionOptions {
  deleteIdentityFile?: boolean
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const headers = new Headers(init?.headers)
  headers.set('Accept', 'application/json')
  if (sessionToken) {
    headers.set('X-Proxy-Manager-Token', sessionToken)
  }
  if (init?.body) {
    headers.set('Content-Type', 'application/json')
  }

  const controller = new AbortController()
  const timeoutMs = requestTimeout(path)
  const timeoutId = window.setTimeout(() => controller.abort(), timeoutMs)
  try {
    const response = await fetch(path, { ...init, headers, signal: controller.signal })
    if (!response.ok) {
      let message = 'Request failed (' + response.status + ')'
      try {
        const body = await response.json() as { error?: string }
        if (body.error) message = body.error
      } catch {
        // Keep the HTTP status as the useful fallback.
      }
      throw new Error(message)
    }
    return response.json() as Promise<T>
  } catch (cause) {
    if (cause instanceof Error && cause.name === 'AbortError') {
      throw new Error('Request timed out after ' + Math.round(timeoutMs / 1000) + ' seconds', { cause })
    }
    throw cause
  } finally {
    window.clearTimeout(timeoutId)
  }
}

export function fetchState(): Promise<ManagerState> {
  return request<ManagerState>('/api/state')
}

export function sendHeartbeat(): Promise<{ ok: boolean }> {
  return request<{ ok: boolean }>('/api/heartbeat', { method: 'POST' })
}

export function runAction(command: ManagerCommand, target?: TargetForm & { name: string }, options: ManagerActionOptions = {}): Promise<ManagerActionResponse> {
  return request<ManagerActionResponse>('/api/action', {
    method: 'POST',
    body: JSON.stringify({ command, target, ...options }),
  })
}
