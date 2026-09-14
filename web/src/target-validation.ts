import type { Target, TargetForm } from './types'

function otherTargetsOnHost(form: TargetForm, targets: Target[]) {
  const host = form.host.trim().toLowerCase()
  return targets.filter((target) => target.id !== form.id && target.host.trim().toLowerCase() === host)
}

export function findRemotePortConflict(form: TargetForm, targets: Target[]) {
  return otherTargetsOnHost(form, targets).find((target) => target.remotePort === form.remoteProxyPort)
}

// These ports are unassigned in the manager; the remote host is checked on install.
export function suggestRemoteProxyPort(form: TargetForm, targets: Target[]): number | undefined {
  const reserved = new Set(otherTargetsOnHost(form, targets).map((target) => target.remotePort))
  const start = Number.isInteger(form.remoteProxyPort) && form.remoteProxyPort >= 1024 && form.remoteProxyPort <= 65535
    ? form.remoteProxyPort
    : 17897
  for (let port = start; port <= 65535; port++) {
    if (!reserved.has(port)) return port
  }
  for (let port = 1024; port < start; port++) {
    if (!reserved.has(port)) return port
  }
}
