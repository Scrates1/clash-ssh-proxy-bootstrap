import { expect, test } from '@playwright/test'
import { spawn } from 'node:child_process'
import { once } from 'node:events'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const repoRoot = fileURLToPath(new URL('../..', import.meta.url))
const sessionStorageKey = 'clash-ssh-proxy-manager.session-token'
let hostProcess
let hostOutput = ''
let managerUrl = ''
let temporaryDirectory = ''

function waitForManagerUrl(process) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error(`Manager did not start in time.\n${hostOutput}`)), 15_000)
    const onData = (chunk) => {
      hostOutput += chunk.toString()
      const match = hostOutput.match(/React UI listening at (http:\/\/127\.0\.0\.1:\d+\/#token=[a-f0-9]+)/)
      if (!match) return
      clearTimeout(timeout)
      process.removeListener('exit', onExit)
      resolve(match[1])
    }
    const onExit = (code) => {
      clearTimeout(timeout)
      reject(new Error(`Manager exited before becoming ready (code ${code}).\n${hostOutput}`))
    }
    process.stdout.on('data', onData)
    process.stderr.on('data', onData)
    process.once('exit', onExit)
  })
}

test.beforeAll(async () => {
  temporaryDirectory = await mkdtemp(join(tmpdir(), 'clash-ssh-browser-test-'))
  const configPath = join(temporaryDirectory, 'config.json')
  await writeFile(configPath, JSON.stringify({
    version: 1,
    proxy: { localHost: '127.0.0.1', localPort: 7897 },
    defaults: { sshPort: 22, identityFile: '~/.ssh/id_ed25519', remoteProxyPort: 17897, noProxyExtra: [] },
    targets: [],
  }), 'utf8')
  hostProcess = spawn('powershell.exe', [
    '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', join(repoRoot, 'proxy-manager-react-host.ps1'),
    '-BrowserTest', '-Port', '18040', '-Config', configPath,
  ], { cwd: repoRoot, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] })
  managerUrl = await waitForManagerUrl(hostProcess)
})

test.afterAll(async () => {
  if (hostProcess?.exitCode === null) {
    const exited = once(hostProcess, 'exit')
    hostProcess.kill()
    await exited
  }
  if (temporaryDirectory) await rm(temporaryDirectory, { recursive: true, force: true })
})

test('loads live state and preserves manager authorization across refresh', async ({ page }) => {
  const token = new URLSearchParams(new URL(managerUrl).hash.slice(1)).get('token')
  expect(token).toMatch(/^[a-f0-9]{32}$/)

  const initialState = page.waitForResponse((response) => response.url().endsWith('/api/state'))
  await page.goto(managerUrl)
  expect((await initialState).status()).toBe(200)
  await expect(page.locator('.mode-pill.live.connected')).toBeVisible()
  await expect.poll(() => page.url()).not.toContain('token=')
  expect(await page.evaluate((key) => sessionStorage.getItem(key), sessionStorageKey)).toBe(token)

  const reloadedState = page.waitForResponse((response) => response.url().endsWith('/api/state'))
  await page.reload()
  expect((await reloadedState).status()).toBe(200)
  await expect(page.locator('.mode-pill.live.connected')).toBeVisible()
  await expect(page.locator('.error-banner')).toHaveCount(0)

  const refreshedState = page.waitForResponse((response) => response.url().endsWith('/api/state'))
  await page.getByRole('button', { name: 'Run check', exact: true }).click()
  expect((await refreshedState).status()).toBe(200)
  await expect(page.locator('.mode-pill.live.connected')).toBeVisible()
})
