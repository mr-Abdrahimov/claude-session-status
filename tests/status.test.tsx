import { expect, test } from 'claude-code/testing'

const BAND = {
  plugin: 'session-status',
  component: 'AbovePrompt',
  props: { hasSurvey: false, bodyColumns: 120, view: {} },
} as const

const PANE = {
  plugin: 'session-status',
  component: 'Pane',
  requestId: 'session-status-all',
  props: {
    title: 'Сессии',
    isFocused: false,
    bodyColumns: 80,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 40 },
    view: {},
  },
} as const

const OUT: [RegExp, string][] = [
  [/git log/, 'abc123full\x1fabc123\x1ffeat: status pane\x1f2 minutes ago'],
  [/rev-parse --abbrev-ref/, 'main'],
  [/rev-parse @\{u\}/, 'abc123full'],
  [/rev-list --count/, '0'],
  [/gh run list/, JSON.stringify([
    { status: 'completed', conclusion: 'failure', workflowName: 'CI', url: 'https://github.com/o/r/actions/runs/1' },
  ])],
]

test('the band and the pane show the session, its agents and CI', async ($, on) => {
  const files = new Map<string, string>()
  on('command.register', () => ({ value: { command: 'x' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('clock.now', () => ({ value: Date.now() }))
  on('clock.every', () => ({ value: undefined }))
  on('clock.after', () => ({ value: undefined }))
  on('env.get', () => ({ value: '/home/me' }))
  on('session.id', () => ({ value: 's1' }))
  on('session.root', () => ({ value: '/w/proj' }))
  on('session.cwd', () => ({ value: '/w/proj' }))
  on('session.model', () => ({ value: 'claude-opus-5-5' }))
  on('session.messages', () => ({ value: [] }))
  on('session.repo', () => ({
    value: { root: '/w/proj', remote: 'git@github.com:o/r.git', internal: false, name: null },
  }))
  on('settings.read', () => ({ value: { effortLevel: 'high' } }))
  on('agent.list', () => ({
    value: [
      { id: 'a1', description: 'review code', type: 'code-reviewer', status: 'running' },
      { id: 'a2', description: 'done one', type: 'Explore', status: 'completed' },
    ],
  }))
  on('fs.exists', () => ({ value: false }))
  on('fs.write', (_, e) => {
    files.set(e.path, e.text)
    return { value: undefined }
  })
  on('fs.list', () => ({
    value: [...files.keys()].map(path => ({
      name: path.split('/').pop(), kind: 'file', size: 1, mtimeMs: Date.now(), isLink: false,
    })),
  }))
  on('fs.read', (_, e) => ({ value: files.get(e.path) ?? '' }))
  on('process.run', (_, e) => {
    const line = e.argv.join(' ')
    const hit = OUT.find(([re]) => re.test(line))
    return { value: { exitCode: hit ? 0 : 1, stdout: hit?.[1] ?? '', stderr: '' } }
  })
  on('turn.start', (_, e) => ({ turnId: e.turnId }))

  await $.session.start({ cwd: '/w/proj', surface: 'desktop', isInteractive: true })
  await $.command.run({ command: 'sessions', args: '' })
  // The GitHub check runs in the background: give it a few host round trips.
  for (let i = 0; i < 200 && ![...files.values()].some(f => f.includes('failure')); i++) {
    // Toggled twice: a round trip through the plugin that leaves the band shown.
    await $.command.run({ command: 'session-band', args: '' })
    await $.command.run({ command: 'session-band', args: '' })
  }

  for (const surface of ['terminal', 'desktop'] as const) {
    const band = await $.ui.mount({ ...BAND, surface })
    expect((await band.find({ type: 'Text', text: /Opus 5\.5 · high/ }))?.text).toBe('Opus 5.5 · high')
    expect((await band.find({ type: 'Text', text: /агентов/ }))?.text).toBe('· агентов 1 (?×1)')
    expect((await band.find({ type: 'Text', text: /сборка упала/ }))?.text).toBe(
      'main abc123 «feat: status pane» 2 minutes ago ✗ сборка упала (CI)',
    )
    // No turn runs, but an agent does: the chat is still working.
    expect((await band.find({ type: 'Text', text: /работает/ }))).toBeDefined()
    expect((await band.find({ type: 'Text', text: /готов/ }))).toBeUndefined()
    await band.unmount()

    const pane = await $.ui.mount({ ...PANE, surface })
    expect((await pane.find({ type: 'Text', text: /^o\/r$/ }))?.text).toBe('o/r')
    expect((await pane.find({ type: 'Text', text: /review code/ }))).toBeDefined()
    await pane.unmount()
  }
})

test('the chat title in the app gets the status mark, and the toggle takes it off', async ($, on) => {
  let title = 'Анализ звонков'
  const titles: string[] = []
  const files = new Map<string, string>()
  const other = {
    id: 'o1', title: 'Чужой проект', cwd: '/w/other', project: 'other', activity: 'idle',
    since: Date.now(), model: 'claude-haiku-5-5', effort: 'low', agents: [],
    updatedAt: Date.now(), git: null,
  }
  files.set('/home/me/.claude/session-status/o1.json', JSON.stringify(other))
  on('command.register', () => ({ value: { command: 'x' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('clock.now', () => ({ value: Date.now() }))
  on('clock.every', () => ({ value: undefined }))
  on('clock.after', () => ({ value: undefined }))
  on('env.get', () => ({ value: '/home/me' }))
  on('store.get', () => ({ value: undefined }))
  on('store.set', () => ({ value: undefined }))
  on('session.id', () => ({ value: 's2' }))
  on('session.root', () => ({ value: '/w/proj' }))
  on('session.cwd', () => ({ value: '/w/proj' }))
  on('session.model', () => ({ value: 'claude-sonnet-5-5' }))
  on('session.messages', () => ({ value: [] }))
  on('session.repo', () => ({
    value: { root: '/w/proj', remote: 'https://github.com/o/r.git', internal: false, name: null },
  }))
  on('settings.read', () => ({ value: {} }))
  on('agent.list', () => ({ value: [] }))
  on('fs.exists', () => ({ value: false }))
  on('fs.write', (_, e) => {
    files.set(e.path, e.text)
    return { value: undefined }
  })
  on('fs.list', () => ({
    value: [...files.keys()].map(path => ({
      name: path.split('/').pop(), kind: 'file', size: 1, mtimeMs: Date.now(), isLink: false,
    })),
  }))
  on('fs.read', (_, e) => ({ value: files.get(e.path) ?? '' }))
  on('process.run', (_, e) => {
    const line = e.argv.join(' ')
    const hit = OUT.find(([re]) => re.test(line))
    return { value: { exitCode: hit ? 0 : 1, stdout: hit?.[1] ?? '', stderr: '' } }
  })
  on('tool.check', () => ({ decision: 'allow' }))
  on('tool.call', (_, e) => {
    if (e.tool === 'mcp__ccd_session_mgmt__set_session_title') {
      title = String((e as unknown as { title: string }).title)
      titles.push(title)
    }
    return {
      result: {},
      text: JSON.stringify({ title, model: 'claude-opus-5-5', effort: 'xhigh' }),
    }
  })

  await $.session.start({ cwd: '/w/proj', surface: 'desktop', isInteractive: true })
  for (let i = 0; i < 200 && title !== '✗ Анализ звонков'; i++) {
    await $.command.run({ command: 'session-band', args: '' })
  }
  expect(title).toBe('✗ Анализ звонков')
  // The mark is replaced, never stacked.
  expect(titles.every(t => /^[●◐✓✗◷○] Анализ звонков$/.test(t))).toBe(true)

  // An idle session shows the effort picked in the app, not settings.json's.
  const band = await $.ui.mount({ ...BAND, surface: 'desktop' })
  expect((await band.find({ type: 'Text', text: /Opus 5\.5/ }))?.text).toBe('Opus 5.5 · xhigh')
  await band.unmount()

  // The project's pane lists this project alone; the other pane lists both.
  const project = await $.ui.mount({ ...PANE, requestId: 'session-status-project', surface: 'desktop' })
  expect(await project.find({ type: 'Text', text: /Анализ звонков/ })).toBeDefined()
  expect(await project.find({ type: 'Text', text: /Чужой проект/ })).toBeUndefined()
  await project.unmount()
  const everything = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await everything.find({ type: 'Text', text: /Чужой проект/ })).toBeDefined()
  await everything.unmount()

  await $.command.run({ command: 'session-title-mark', args: '' })
  expect(title).toBe('Анализ звонков')
})

test('uncommitted changes offer commit, commit and push, push or wait', async ($, on) => {
  const prompts: string[] = []
  on('command.register', () => ({ value: { command: 'x' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('clock.now', () => ({ value: Date.now() }))
  on('clock.every', () => ({ value: undefined }))
  on('clock.after', () => ({ value: undefined }))
  on('env.get', () => ({ value: '/home/me' }))
  on('store.get', () => ({ value: true }))
  on('session.id', () => ({ value: 's3' }))
  on('session.root', () => ({ value: '/w/proj' }))
  on('session.cwd', () => ({ value: '/w/proj' }))
  on('session.model', () => ({ value: 'claude-opus-5-5' }))
  on('session.messages', () => ({ value: [] }))
  on('session.repo', () => ({
    value: { root: '/w/proj', remote: 'git@github.com:o/r.git', internal: false, name: null },
  }))
  on('settings.read', () => ({ value: {} }))
  on('agent.list', () => ({ value: [] }))
  on('fs.exists', () => ({ value: false }))
  on('fs.write', () => ({ value: undefined }))
  on('fs.list', () => ({ value: [] }))
  on('fs.read', () => ({ value: '' }))
  on('process.run', (_, e) => {
    const line = e.argv.join(' ')
    if (/status --porcelain/.test(line)) {
      return { value: { exitCode: 0, stdout: ' M a.ts\n M b.ts', stderr: '' } }
    }
    if (/rev-list --count/.test(line)) return { value: { exitCode: 0, stdout: '1', stderr: '' } }
    const hit = OUT.find(([re]) => re.test(line))
    return { value: { exitCode: hit ? 0 : 1, stdout: hit?.[1] ?? '', stderr: '' } }
  })
  // The engine's own band, drawn while the mod has nothing to show.
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })
  on('prompt.read', () => ({ value: { text: '', cursor: 0 } }))
  on('prompt.fill', (_, e) => {
    prompts.push(e.text)
    return { isFilled: true }
  })
  on('ui.toast', () => ({ value: undefined }))

  await $.session.start({ cwd: '/w/proj', surface: 'desktop', isInteractive: true })
  const band = await $.ui.mount({ ...BAND, surface: 'desktop' })
  for (let i = 0; i < 200 && (await band.find({ type: 'Text', text: /не закоммичено файлов/ })) === undefined; i++) {
    await $.command.run({ command: 'session-band', args: '' })
    await $.command.run({ command: 'session-band', args: '' })
  }
  expect((await band.find({ type: 'Text', text: /не закоммичено файлов/ }))?.text).toBe(
    '✎ не закоммичено файлов: 2 · не запушено коммитов: 1',
  )

  await band.press({ key: 'commit' })
  expect(prompts.length).toBe(1)
  expect(prompts[0]).toContain('Закоммить изменения этой задачи')
  expect(prompts[0]).toContain('Не пушь')
  // A choice made hides the offer for this commit.
  expect(await band.find({ type: 'Text', text: /не закоммичено файлов/ })).toBeUndefined()
  await band.unmount()
})

test('no commit is offered while a background agent still works', async ($, on) => {
  const prompts: string[] = []
  on('command.register', () => ({ value: { command: 'x' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('clock.now', () => ({ value: Date.now() }))
  on('clock.every', () => ({ value: undefined }))
  on('clock.after', () => ({ value: undefined }))
  on('env.get', () => ({ value: '/home/me' }))
  on('store.get', () => ({ value: true }))
  on('session.id', () => ({ value: 's4' }))
  on('session.root', () => ({ value: '/w/proj' }))
  on('session.cwd', () => ({ value: '/w/proj' }))
  on('session.model', () => ({ value: 'claude-opus-5-5' }))
  on('session.messages', () => ({ value: [] }))
  on('session.repo', () => ({
    value: { root: '/w/proj', remote: 'git@github.com:o/r.git', internal: false, name: null },
  }))
  on('settings.read', () => ({ value: {} }))
  on('agent.list', () => ({
    value: [{ id: 'a1', description: 'экраны', type: 'general-purpose', status: 'running' }],
  }))
  on('fs.exists', () => ({ value: false }))
  on('fs.write', () => ({ value: undefined }))
  on('fs.list', () => ({ value: [] }))
  on('fs.read', () => ({ value: '' }))
  on('process.run', (_, e) => {
    const line = e.argv.join(' ')
    if (/status --porcelain/.test(line)) {
      return { value: { exitCode: 0, stdout: ' M a.ts\n M b.ts', stderr: '' } }
    }
    if (/rev-list --count/.test(line)) return { value: { exitCode: 0, stdout: '1', stderr: '' } }
    const hit = OUT.find(([re]) => re.test(line))
    return { value: { exitCode: hit ? 0 : 1, stdout: hit?.[1] ?? '', stderr: '' } }
  })
  // The engine's own band, drawn while the mod has nothing to show.
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })
  on('prompt.read', () => ({ value: { text: '', cursor: 0 } }))
  on('prompt.fill', (_, e) => {
    prompts.push(e.text)
    return { isFilled: true }
  })
  on('ui.toast', () => ({ value: undefined }))

  await $.session.start({ cwd: '/w/proj', surface: 'desktop', isInteractive: true })
  const band = await $.ui.mount({ ...BAND, surface: 'desktop' })
  for (let i = 0; i < 200 && (await band.find({ type: 'Text', text: /изменено|не закоммичено: 2/ })) === undefined; i++) {
    await $.command.run({ command: 'session-band', args: '' })
    await $.command.run({ command: 'session-band', args: '' })
  }
  // The git state has arrived, yet the turn's work goes on in the background.
  expect(await band.find({ type: 'Text', text: /не закоммичено: 2/ })).toBeDefined()
  expect(await band.find({ type: 'Text', text: /работает/ })).toBeDefined()
  expect(await band.find({ type: 'Text', text: /не закоммичено файлов/ })).toBeUndefined()
  await band.unmount()
})
