import { useCallback, useEffect, useRef, useState } from 'react'
import { fetchState, sendHeartbeat } from './api'
import { demoState, emptyState, normalizeState } from './manager-state'
import { formatManagerError } from './manager-errors'
import type { ManagerState } from './types'

type Translate = (key: string) => string
type BridgeStatus = 'checking' | 'connected' | 'offline'

export function useManagerSession(demoPreview: boolean, t: Translate) {
  const [manager, setManager] = useState<ManagerState>(() => demoPreview ? demoState : emptyState)
  const [selectedId, setSelectedId] = useState(() => demoPreview ? 'tgt-demo-tokyo' : '')
  const [loading, setLoading] = useState(!demoPreview)
  const [error, setError] = useState('')
  const [bridgeStatus, setBridgeStatus] = useState<BridgeStatus>(demoPreview ? 'connected' : 'checking')
  const loadRequestRef = useRef(0)
  const disconnectedRef = useRef(false)

  const load = useCallback(async () => {
    if (demoPreview) return
    const requestId = ++loadRequestRef.current
    setLoading(true)
    setError('')
    try {
      const next = normalizeState(await fetchState())
      if (requestId !== loadRequestRef.current) return
      setManager(next)
      disconnectedRef.current = false
      setBridgeStatus('connected')
      setSelectedId((current) => {
        if (!next.targets.length) return ''
        return next.targets.some((target) => target.id === current) ? current : next.targets[0].id
      })
    } catch (cause) {
      if (requestId !== loadRequestRef.current) return
      setBridgeStatus('offline')
      disconnectedRef.current = true
      setError(formatManagerError(cause, t('Unable to reach the manager bridge.'), t))
    } finally {
      if (requestId === loadRequestRef.current) setLoading(false)
    }
  }, [demoPreview, t])

  useEffect(() => {
    if (demoPreview) return
    const timer = window.setTimeout(() => void load(), 0)
    return () => window.clearTimeout(timer)
  }, [demoPreview, load])

  useEffect(() => {
    if (demoPreview) return
    let disposed = false
    let inFlight = false
    let refreshRequested = false
    const heartbeat = async (refresh = false) => {
      refreshRequested ||= refresh
      if (inFlight || disposed) return
      inFlight = true
      try {
        await sendHeartbeat()
        if (disposed) return
        setBridgeStatus('connected')
        if (refreshRequested || disconnectedRef.current) {
          refreshRequested = false
          disconnectedRef.current = false
          void load()
        }
      } catch (cause) {
        if (disposed) return
        disconnectedRef.current = true
        setBridgeStatus('offline')
        setError(formatManagerError(cause, t('Unable to reach the manager bridge.'), t))
      } finally {
        inFlight = false
      }
    }
    const resume = () => { if (!document.hidden) void heartbeat(true) }
    const reconnect = () => { void heartbeat(true) }
    const timer = window.setInterval(() => void heartbeat(), 10000)
    window.addEventListener('focus', resume)
    document.addEventListener('visibilitychange', resume)
    window.addEventListener('online', reconnect)
    void heartbeat()
    return () => {
      disposed = true
      window.clearInterval(timer)
      window.removeEventListener('focus', resume)
      document.removeEventListener('visibilitychange', resume)
      window.removeEventListener('online', reconnect)
    }
  }, [demoPreview, load, t])

  return {
    manager,
    setManager,
    selectedId,
    setSelectedId,
    loading,
    error,
    setError,
    bridgeStatus,
    load,
  }
}
