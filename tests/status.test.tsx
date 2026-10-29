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
    expect((await band.find({ type: 'Text', text: /работает/ }))).toBeUndefined()
    expect((await band.find({ type: 'Text', text: /готов/ }))).toBeDefined()
    await band.unmount()

    const pane = await $.ui.mount({ ...PANE, surface })
    expect((await pane.find({ type: 'Text', text: /^o\/r$/ }))?.text).toBe('o/r')
    expect((await pane.find({ type: 'Text', text: /review code/ }))).toBeDefined()
    await pane.unmount()
  }
})
