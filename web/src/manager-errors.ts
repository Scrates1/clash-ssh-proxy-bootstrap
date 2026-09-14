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
      case 'MANAGER_UNREACHABLE':
        return t('Unable to connect to the local manager. Retry, or reopen the manager with Open-ProxyManager.vbs if the problem persists.')
      case 'MANAGER_TIMEOUT':
        return t('The local manager did not respond within {seconds} seconds. An operation may still be running. Wait and retry.', cause.details)
      case 'INVALID_SESSION':
        return t('This manager session is no longer valid. Reopen the manager with Open-ProxyManager.vbs to connect to the current session.')
      case 'TARGET_CONNECTION_CHANGE_NOT_SUPPORTED':
        return t('The Linux host and account for {name} cannot be changed in place. Remove this target, then add the new host or account.', cause.details)
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
