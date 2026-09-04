import { useCallback, useEffect, useRef, useState } from 'react'
import { fetchState, sendHeartbeat } from './api'
import { demoState, emptyState, normalizeState } from './manager-state'
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

  const load = useCallback(async () => {
    if (demoPreview) return
    const requestId = ++loadRequestRef.current
    setLoading(true)
    setError('')
    try {
      const next = normalizeState(await fetchState())
      if (requestId !== loadRequestRef.current) return
      setManager(next)
      setBridgeStatus('connected')
      setSelectedId((current) => {
        if (!next.targets.length) return ''
        return next.targets.some((target) => target.id === current) ? current : next.targets[0].id
      })
    } catch (cause) {
      if (requestId !== loadRequestRef.current) return
      setBridgeStatus('offline')
      setError(cause instanceof Error ? cause.message : t('Unable to reach the manager bridge.'))
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
    const timer = window.setInterval(() => {
      void sendHeartbeat()
        .then(() => setBridgeStatus('connected'))
        .catch(() => setBridgeStatus('offline'))
    }, 10000)
    return () => window.clearInterval(timer)
  }, [demoPreview])

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
