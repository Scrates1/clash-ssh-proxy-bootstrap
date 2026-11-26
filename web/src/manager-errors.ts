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
      case 'DUPLICATE_IDENTITY':
        return t('Configuration error: two targets share the same SSH private key. Each target must use its own private key. Run proxy-manager.ps1 doctor for details.')
      case 'CONFIG_INVALID':
        return t('Configuration error: {message}', { message: cause.message })
      case 'ELEVATION_REQUIRED':
        return t('Administrator privileges are required to modify scheduled tasks. Reopen the manager with Open-ProxyManager.vbs and approve UAC.')
      case 'BOOTSTRAP_IDENTITY_INVALID':
        return t('The existing SSH private key path is invalid or outside your user profile directory. Select a valid local private key file and retry.')
      case 'HOST_KEY_NOT_TRUSTED':
        return t('The SSH host key for {destination} is not trusted yet. Verify the host fingerprint first or use interactive SSH setup once.', cause.details)
      case 'BOOTSTRAP_AUTH_FAILED':
        return t('The existing SSH private key could not authenticate to {destination}. Ensure it is authorized on the server and loaded in ssh-agent if passphrase-protected.', cause.details)
      case 'BOOTSTRAP_TIMEOUT':
        return t('Timed out while deploying the dedicated SSH key to {destination}. Check SSH connectivity and retry.', cause.details)
    }
  }
  return cause instanceof Error ? cause.message : fallback
}
