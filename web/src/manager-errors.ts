type Details = Record<string, string | number>
type Translate = (key: string, values?: Details) => string

export class ManagerActionError extends Error {
  constructor(message: string, readonly code?: string, readonly details: Details = {}) {
    super(message)
    this.name = 'ManagerActionError'
  }
}

export function formatManagerError(cause: unknown, fallback: string, t: Translate) {
  if (cause instanceof ManagerActionError) {
    switch (cause.code) {
      case 'REMOTE_PROXY_PORT_ASSIGNED':
        return t('Port {port} on {host} is assigned to {owner} ({user}). Edit the connection details and choose a different remote proxy port.', cause.details)
      case 'REMOTE_PROXY_PORT_IN_USE':
        return t('Port {port} on {host} is already listening. Edit the connection details and choose another remote proxy port. No files or scheduled tasks were changed.', cause.details)
      case 'REMOTE_PROXY_PORT_CHECK_FAILED':
        return t('Could not check port {port} on {host}. Check SSH connectivity and that Bash and timeout are available, then retry. No files or scheduled tasks were changed.', cause.details)
      case 'PROXY_VERIFICATION_FAILED':
        return t('SSH login succeeded, but the proxy check through {host}:{port} failed. Check the local Clash proxy at {localProxy}, SSH forwarding permissions, and access to the health endpoints, then retry.', cause.details)
    }
  }
  return cause instanceof Error ? cause.message : fallback
}
