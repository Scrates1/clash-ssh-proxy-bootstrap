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
let testConfigPath = ''

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
  testConfigPath = configPath
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

for (const language of ['en', 'zh-CN']) {
  test(`explains a disconnected bridge and refreshes stale state when heartbeats recover in ${language}`, async ({ page }) => {
    const chinese = language === 'zh-CN'
    let available = true
    let recovered = false
    await page.clock.install()
    await page.route('**/api/state', (route) => available ? route.fulfill({ json: {
      mode: 'live', configPath: 'isolated-test-config',
      localProxy: { host: '127.0.0.1', port: 7897, up: true },
      checkedAt: new Date().toISOString(), logs: [],
      targets: [{ ...primaryTarget, name: recovered ? 'recovered-account' : primaryTarget.name }],
    } }) : route.abort('connectionrefused'))
    await page.route('**/api/heartbeat', (route) => available
      ? route.fulfill({ json: { ok: true } }) : route.abort('connectionrefused'))
    const url = new URL(managerUrl)
    url.searchParams.set('lang', language)
    await page.goto(url.toString())
    await expect(page.locator('.mode-pill.live.connected')).toBeVisible()
    await page.locator('.sidebar').getByRole('button', { name: chinese ? /^目标主机/ : /^Targets/ }).click()
    await expect(page.locator('.target-row').getByText('primary-account', { exact: true })).toBeVisible()
    available = false
    await page.getByRole('button', { name: chinese ? '刷新状态' : 'Refresh status', exact: true }).click()
    await expect(page.locator('.mode-pill.live.offline')).toBeVisible()
    await expect(page.locator('.error-banner')).toContainText(chinese ? '无法连接本地管理器后台' : 'Unable to connect to the local manager')
    await expect(page.locator('.error-banner')).toContainText('Open-ProxyManager.vbs')
    await expect(page.locator('.error-banner')).toContainText(chinese ? '当前显示上一次成功获取的数据。' : 'Showing the last successful snapshot.')
    await expect(page.locator('.target-row').getByText('primary-account', { exact: true })).toBeVisible()
    available = true
    recovered = true
    await page.clock.fastForward(10000)
    await expect(page.locator('.target-row').getByText('recovered-account', { exact: true })).toBeVisible()
    await expect(page.locator('.error-banner')).toHaveCount(0)
    await expect(page.locator('.mode-pill.live.connected')).toBeVisible()
  })
}

test('refreshes on focus, visibility resume and network recovery', async ({ page }) => {
  let stateRequests = 0
  await page.route('**/api/state', (route) => {
    stateRequests++
    return route.fulfill({ json: {
      mode: 'live', configPath: 'isolated-test-config', targets: [], logs: [],
      checkedAt: new Date().toISOString(), localProxy: { host: '127.0.0.1', port: 7897, up: true },
    } })
  })
  const heartbeat = page.waitForResponse((response) => response.url().endsWith('/api/heartbeat'))
  await page.goto(managerUrl)
  await (await heartbeat).finished()
  await expect(page.locator('.mode-pill.live.connected')).toBeVisible()
  for (const event of ['focus', 'visibilitychange', 'online']) {
    const previousRequests = stateRequests
    await page.evaluate((type) => {
      const target = type === 'visibilitychange' ? document : window
      target.dispatchEvent(new Event(type))
    }, event)
    await expect.poll(() => stateRequests).toBeGreaterThan(previousRequests)
    await expect(page.locator('.mode-pill.live.connected')).toBeVisible()
  }
})

test('keeps one heartbeat in flight and retains a resume refresh while it is pending', async ({ page }) => {
  let stateRequests = 0
  let heartbeatRequests = 0
  let pendingHeartbeat
  await page.clock.install()
  await page.route('**/api/state', (route) => {
    stateRequests++
    return route.fulfill({ json: {
      mode: 'live', configPath: 'isolated-test-config', targets: [], logs: [],
      checkedAt: new Date().toISOString(), localProxy: { host: '127.0.0.1', port: 7897, up: true },
    } })
  })
  await page.route('**/api/heartbeat', (route) => {
    heartbeatRequests++
    if (heartbeatRequests === 1) { pendingHeartbeat = route; return }
    return route.fulfill({ json: { ok: true } })
  })
  await page.goto(managerUrl)
  await expect(page.locator('.mode-pill.live.connected')).toBeVisible()
  await expect.poll(() => heartbeatRequests).toBe(1)
  await page.clock.fastForward(10000)
  await page.evaluate(() => window.dispatchEvent(new Event('focus')))
  expect(heartbeatRequests).toBe(1)
  const response = page.waitForResponse((item) => item.url().endsWith('/api/heartbeat'))
  await pendingHeartbeat.fulfill({ json: { ok: true } })
  await (await response).finished()
  await expect.poll(() => stateRequests).toBe(2)
  await page.clock.fastForward(10000)
  await expect.poll(() => heartbeatRequests).toBe(2)
  await expect(page.locator('.error-banner')).toHaveCount(0)
})

const primaryTarget = {
  id: 'tgt-primary', name: 'primary-account', host: 'linux.example.com', user: 'first',
  destination: 'first@linux.example.com', task: 'PrimaryTask', taskState: 'Disabled',
  enabled: false, ssh: 'UNKNOWN', proxy: 'BLOCKED', remotePort: 17897,
  sshPort: 22, identityFile: 'primary-key', identityManaged: true, noProxyExtra: [],
}

async function showFixtureState(page, targets, language = 'en') {
  await page.route('**/api/state', (route) => route.fulfill({ json: {
    mode: 'live', configPath: 'isolated-test-config',
    localProxy: { host: '127.0.0.1', port: 7897, up: true },
    checkedAt: new Date().toISOString(), logs: [], targets,
  } }))
  const url = new URL(managerUrl)
  url.searchParams.set('lang', language)
  await page.goto(url.toString())
  await expect(page.locator('.mode-pill.live.connected')).toBeVisible()
}

for (const language of ['en', 'zh-CN']) {
  test(`warns about a conflicting port and offers a usable configuration in ${language}`, async ({ page }) => {
    const chinese = language === 'zh-CN'
    const actions = []
    await page.route('**/api/action', async (route) => {
      actions.push(route.request().postDataJSON())
      await route.fulfill({ json: { ok: true, ready: false } })
    })
    await showFixtureState(page, [primaryTarget, { ...primaryTarget, id: 'tgt-next', name: 'next-account', user: 'next', remotePort: 17898 }], language)
    await page.getByRole('button', { name: chinese ? '添加目标' : 'Add target', exact: true }).click()
    await page.getByLabel(chinese ? '目标名称' : 'Target name', { exact: true }).fill('another-account')
    await page.getByLabel(chinese ? 'Linux 主机 / IP' : 'Linux host / IP', { exact: true }).fill('LINUX.example.com')
    await page.getByLabel(chinese ? 'Linux 用户' : 'Linux user', { exact: true }).fill('second')
    await page.getByLabel(chinese ? 'SSH 端口' : 'SSH port', { exact: true }).fill('2222')
    const port = page.getByLabel(chinese ? '远程代理端口' : 'Remote proxy port', { exact: true })
    const next = page.getByRole('button', { name: chinese ? '继续检查 SSH' : 'Continue to SSH check', exact: true })
    await expect(port).toHaveAttribute('aria-invalid', 'true')
    await expect(page.getByRole('alert')).toContainText('primary-account')
    await expect(page.getByRole('alert')).toContainText('17897')
    await expect(next).toBeDisabled()
    await port.press('Enter')
    expect(actions).toEqual([])
    await page.screenshot({ path: test.info().outputPath('port-conflict.png') })
    await page.getByRole('button', { name: chinese ? '使用端口 17899' : 'Use port 17899', exact: true }).click()
    await expect(port).toHaveValue('17899')
    await expect(page.getByRole('alert')).toHaveCount(0)
    await expect(next).toBeEnabled()
    await next.click()
    await expect.poll(() => actions.length).toBe(1)
    expect(actions[0]).toMatchObject({ command: 'prepare-ssh', target: { remoteProxyPort: 17899 } })
  })
}

test('shows a remote listener conflict in the wizard and lets the user edit without losing the form', async ({ page }) => {
  await page.route('**/api/action', async (route) => {
    const action = route.request().postDataJSON()
    if (action.command === 'prepare-ssh') {
      await route.fulfill({ json: { ok: true, ready: true } })
    } else {
      await route.fulfill({ status: 500, json: {
        code: 'REMOTE_PROXY_PORT_IN_USE', error: 'Raw remote listener error',
        details: { host: 'linux.example.com', port: 17897 },
      } })
    }
  })
  await showFixtureState(page, [], 'zh-CN')
  await page.getByRole('button', { name: '添加目标', exact: true }).click()
  await page.getByLabel('目标名称', { exact: true }).fill('new-account')
  await page.getByLabel('Linux 主机 / IP', { exact: true }).fill('linux.example.com')
  await page.getByLabel('Linux 用户', { exact: true }).fill('second')
  await page.getByRole('button', { name: '继续检查 SSH', exact: true }).click()
  await expect(page.getByRole('alert')).toContainText('端口 17897 已被占用')
  await expect(page.getByRole('alert')).toContainText('linux.example.com')
  await page.getByRole('button', { name: '编辑连接信息', exact: true }).click()
  await expect(page.getByLabel('目标名称', { exact: true })).toHaveValue('new-account')
  await expect(page.getByLabel('Linux 用户', { exact: true })).toHaveValue('second')
  await page.getByLabel('远程代理端口', { exact: true }).fill('17898')
  await expect(page.getByRole('button', { name: '继续检查 SSH', exact: true })).toBeEnabled()
})

test('allows editing the current port and shows update failures inside the modal', async ({ page }) => {
  await page.route('**/api/action', (route) => route.fulfill({ status: 500, json: {
    code: 'PROXY_VERIFICATION_FAILED', error: 'Raw verification error',
    details: { host: 'linux.example.com', port: 17897, localProxy: '127.0.0.1:7897' },
  } }))
  await showFixtureState(page, [primaryTarget])
  await page.getByRole('button', { name: /Targets/ }).first().click()
  await page.locator('.target-row').filter({ hasText: 'primary-account' }).click()
  await page.getByRole('button', { name: 'Edit details', exact: true }).click()
  await expect(page.getByLabel('Remote proxy port', { exact: true })).toHaveAttribute('aria-invalid', 'false')
  await page.getByRole('button', { name: 'Save changes', exact: true }).click()
  await expect(page.locator('.modal-card').getByRole('alert')).toContainText('SSH login succeeded')
  await expect(page.locator('.modal-card').getByRole('alert')).toContainText('127.0.0.1:7897')
})

test('preserves structured port errors through the real manager API before SSH setup', async ({ request }) => {
  const config = {
    version: 1,
    proxy: { localHost: '127.0.0.1', localPort: 7897 },
    defaults: { sshPort: 22, identityFile: '~/.ssh/id_ed25519', remoteProxyPort: 17897, noProxyExtra: [] },
    targets: [{
      id: 'tgt-primary', name: 'primary-account', host: 'linux.example.com', user: 'first',
      taskName: 'BrowserPortFixture', enabled: false, remoteProxyPort: 17897,
      identityFile: join(temporaryDirectory, 'unused-fixture-identity'),
    }],
  }
  await writeFile(testConfigPath, JSON.stringify(config), 'utf8')
  try {
    const url = new URL(managerUrl)
    const token = new URLSearchParams(url.hash.slice(1)).get('token')
    const response = await request.post(new URL('/api/action', url).toString(), {
      headers: { 'X-Proxy-Manager-Token': token },
      data: { command: 'prepare-ssh', target: {
        id: 'tgt-new', name: 'second-account', host: 'linux.example.com', user: 'second',
        sshPort: 22, remoteProxyPort: 17897, identityFile: '', taskName: '', noProxyExtra: '',
      } },
    })
    expect(response.status()).toBe(500)
    expect(await response.json()).toMatchObject({
      code: 'REMOTE_PROXY_PORT_ASSIGNED',
      details: { host: 'linux.example.com', port: 17897, owner: 'primary-account', user: 'first' },
    })
  } finally {
    await writeFile(testConfigPath, JSON.stringify({ ...config, targets: [] }), 'utf8')
  }
})

test('rejects invalid static paths and keeps serving requests without a session token', async ({ request }) => {
  const url = new URL(managerUrl)
  for (const path of ['/file%7Cname', '/file%22name', '/file%3Aname', '/file%3Fname']) {
    const invalid = await request.get(new URL(path, url).toString())
    expect(invalid.status(), path).toBe(400)
    const page = await request.get(new URL('/', url).toString())
    expect(page.status()).toBe(200)
    expect(await page.text()).toContain('<div id="root"></div>')
  }
  const token = new URLSearchParams(url.hash.slice(1)).get('token')
  const heartbeat = await request.post(new URL('/api/heartbeat', url).toString(), {
    headers: { 'X-Proxy-Manager-Token': token },
  })
  expect(heartbeat.status()).toBe(200)
})

for (const language of ['en', 'zh-CN']) {
  test(`repairs SSH for an existing disabled target without reinstalling in ${language}`, async ({ page }) => {
    const chinese = language === 'zh-CN'
    const actions = []
    let ready = false
    await page.route('**/api/action', (route) => {
      const action = route.request().postDataJSON()
      actions.push(action)
      return route.fulfill({ json: action.command === 'prepare-ssh'
        ? { ok: true, ready, interactionRequired: !ready }
        : { ok: true, alreadyRunning: false } })
    })
    await showFixtureState(page, [{ ...primaryTarget, ssh: 'FAIL' }], language)
    await page.locator('.nav-item').filter({ hasText: chinese ? '目标主机' : 'Targets' }).click()
    await page.locator('.target-row').click()
    await page.getByRole('button', { name: chinese ? '配置 SSH 登录' : 'Configure SSH login', exact: true }).click()
    const modal = page.locator('.modal-card')
    await expect(modal).toContainText(chinese ? '完成 SSH 配置窗口' : 'Finish the SSH setup window')
    const verify = modal.getByRole('button', { name: chinese ? '验证 SSH' : 'Verify SSH', exact: true })
    await expect(verify).toBeEnabled()
    await verify.click()
    await expect(modal).toContainText(chinese ? 'SSH 密钥仍未就绪' : 'SSH key is still not ready')
    ready = true
    await verify.click()
    await expect(modal).toContainText(chinese ? 'SSH 登录已就绪' : 'SSH login is ready')
    expect(actions.map((action) => action.command)).toEqual(['prepare-ssh', 'bootstrap-key', 'prepare-ssh', 'prepare-ssh'])
    expect(actions.every((action) => action.target.id === primaryTarget.id)).toBe(true)
    await modal.locator('.modal-actions').getByRole('button', { name: chinese ? '关闭' : 'Close', exact: true }).click()
    await expect(page.locator('.target-row')).toContainText(chinese ? '已禁用' : 'Disabled')
  })
}

test('shows SSH readiness for an existing target without opening an unnecessary console', async ({ page }) => {
  const actions = []
  await page.route('**/api/action', route => {
    actions.push(route.request().postDataJSON().command)
    return route.fulfill({ json: { ok: true, ready: true } })
  })
  await showFixtureState(page, [primaryTarget])
  await page.locator('.nav-item').filter({ hasText: 'Targets' }).click()
  await page.locator('.target-row').click()
  await page.getByRole('button', { name: 'Configure SSH login', exact: true }).click()
  await expect(page.locator('.modal-card')).toContainText('SSH login is ready')
  expect(actions).toEqual(['prepare-ssh'])
})

test('keeps connection identity fixed while allowing ports and NO_PROXY to be edited', async ({ page }) => {
  const actions = []
  await page.route('**/api/action', route => {
    actions.push(route.request().postDataJSON())
    return route.fulfill({ json: { ok: true } })
  })
  await showFixtureState(page, [{ ...primaryTarget, noProxyExtra: ['intranet.example.com'] }])
  await page.locator('.nav-item').filter({ hasText: 'Targets' }).click()
  await page.locator('.target-row').click()
  await page.getByRole('button', { name: 'Edit details', exact: true }).click()
  await expect(page.getByLabel('Linux host / IP', { exact: true })).toHaveAttribute('readonly')
  await expect(page.getByLabel('Linux user', { exact: true })).toHaveAttribute('readonly')
  await expect(page.locator('.modal-card')).toContainText('remove this target and add a new one')
  await page.getByLabel('SSH port', { exact: true }).fill('2222')
  await page.getByLabel('Extra NO_PROXY').fill('')
  await page.getByRole('button', { name: 'Save changes', exact: true }).click()
  await expect(page.locator('.modal-card')).toHaveCount(0)
  expect(actions).toMatchObject([{ command: 'update', target: {
    id: primaryTarget.id, host: primaryTarget.host, user: primaryTarget.user,
    sshPort: 2222, noProxyExtra: '',
  } }])
})
