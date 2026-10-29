import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type {
  Activity,
  AgentRow,
  CiState,
  GitStatus,
  SessionRecord,
} from '../types'

const PANE = 'session-status-all'
const PANE_TITLE = 'Сессии'
const HEARTBEAT_MS = 15_000
const GIT_POLL_MS = 60_000
// A record whose session has not written for this long is shown as closed.
const STALE_MS = 3 * HEARTBEAT_MS
// Records older than this are not shown in the pane at all.
const KEEP_MS = 3 * 24 * 60 * 60 * 1000

// Change a tag when its value's fields change: an older stored value is dropped.
const self = atom({ plugin: 'session-status', key: 'self' } as const, null, {
  shape: 'self-2',
})
const all = atom({ plugin: 'session-status', key: 'all' } as const, [], {
  shape: 'all-2',
})
const isBandHidden = atom(
  { plugin: 'session-status', key: 'isBandHidden' } as const,
  false,
)

type Step = { model: string; effort: string | null }
type Run = { status: string; conclusion: string; workflowName: string; url: string }

const ACTIVE_AGENT = new Set(['pending', 'running', 'waiting'])
const FAILED_RUN = new Set(['failure', 'cancelled', 'timed_out', 'startup_failure'])

// This process's view of its own session; every session's record lives in a
// file of its own under ~/.claude/session-status, which the pane reads.
// Module variables start over on a reload, and session.start runs again.
const me = {
  activity: 'idle' as Activity,
  since: 0,
  model: '',
  effort: null as string | null,
  title: '',
  git: null as GitStatus | null,
  dir: '',
  id: '',
  cwd: '',
  isGitBusy: false,
  isGitDirty: false,
}
const agentSteps = new Map<string, Step>()
// Tool calls whose permission prompt is open, by tool_use_id.
const asking = new Set<string>()
let publishing: Promise<void> = Promise.resolve()
const bins = new Map<string, string>()

function prettyModel(id: string): string {
  const named = /(opus|sonnet|haiku|fable)/i.exec(id)?.[1]
  if (named === undefined) return id
  const family = named.slice(0, 1).toUpperCase() + named.slice(1).toLowerCase()
  // New ids: claude-opus-5-5; old ones put the version first: claude-3-5-sonnet-2024…
  const m =
    /(?:opus|sonnet|haiku|fable)-(\d{1,2})(?:-(\d{1,2}))?(?!\d)/i.exec(id) ??
    /claude-(\d{1,2})(?:-(\d{1,2}))?-(?:opus|sonnet|haiku|fable)/i.exec(id)
  const [, major, minor] = m ?? []
  const version = major === undefined ? '' : minor === undefined ? ` ${major}` : ` ${major}.${minor}`
  return `${family}${version}${id.includes('[1m]') ? ' 1M' : ''}`
}

function shortModel(id: string): string {
  return /(opus|sonnet|haiku|fable)/i.exec(id)?.[1]?.toLowerCase() ?? id
}

function ago(ms: number): string {
  const s = Math.max(0, Math.round(ms / 1000))
  if (s < 60) return `${s}с`
  const m = Math.floor(s / 60)
  if (m < 60) return `${m}м`
  const h = Math.floor(m / 60)
  if (h < 24) return `${h}ч ${m % 60}м`
  return `${Math.floor(h / 24)}д`
}

function parseRepo(remote: string | null): string | null {
  if (remote === null) return null
  // https://github.com/o/r, git@github.com:o/r.git, ssh://git@github.com:22/o/r,
  // and SSH host aliases such as git@github.com-work:o/r.git.
  const m =
    /(?:^|[/@])github\.com[^:/]*[:/](?:\d+\/)?([^/\s]+)\/([^/\s]+?)(?:\.git)?\/?$/.exec(remote)
  return m === null ? null : `${m[1]}/${m[2]}`
}

// The app prepends system-reminder blocks and other tags to a prompt: the
// title is the first line of what the person typed.
function firstLine(text: string): string {
  const typed = text
    .replace(/<([a-z][\w-]*)[^>]*>[\s\S]*?<\/\1>/gi, '')
    .replace(/<[^>]+>/g, '')
  const line = typed.split('\n').map(l => l.trim()).find(l => l !== '') ?? ''
  return line.slice(0, 80)
}

function effortOf(value: unknown): string | null {
  return value === undefined || value === null ? null : String(value)
}

function fire(work: Promise<unknown>): void {
  void work.catch(() => undefined)
}

function isLive(record: SessionRecord, now: number): boolean {
  return record.activity !== 'ended' && now - record.updatedAt < STALE_MS
}

function ciFromRuns(all: Run[]): { ci: CiState; name: string; url: string | null } {
  // gh lists newest first: a rerun or a newer run of a workflow replaces the older.
  const seen = new Set<string>()
  const runs = all.filter(r => !seen.has(r.workflowName) && seen.add(r.workflowName))
  if (runs.length === 0) return { ci: 'none', name: '', url: null }
  const failed = runs.find(r => FAILED_RUN.has(r.conclusion))
  if (failed !== undefined) {
    return { ci: 'failure', name: failed.workflowName, url: failed.url }
  }
  const running = runs.find(r => r.status !== 'completed')
  if (running !== undefined) {
    return { ci: 'pending', name: running.workflowName, url: running.url }
  }
  return {
    ci: 'success',
    name: [...new Set(runs.map(r => r.workflowName))].join(', '),
    url: runs[0]?.url ?? null,
  }
}

// The desktop app's PATH may lack Homebrew: find the binary ourselves.
async function bin($: EngineInterface, name: string): Promise<string> {
  const known = bins.get(name)
  if (known !== undefined) return known
  for (const prefix of ['/opt/homebrew/bin/', '/usr/local/bin/', '/usr/bin/']) {
    if (await $.fs.exists(prefix + name).catch(() => false)) {
      bins.set(name, prefix + name)
      return prefix + name
    }
  }
  bins.set(name, name)
  return name
}

async function run($: EngineInterface, argv: string[], at: string): Promise<string | null> {
  const [name = '', ...rest] = argv
  const result = await $.process
    .run([await bin($, name), ...rest], { cwd: at, timeoutMs: 20_000 })
    .catch(() => null)
  if (result === null || result.exitCode !== 0) return null
  return result.stdout.trim()
}

async function ciOf($: EngineInterface, slug: string, sha: string, at: string) {
  const runs = await run(
    $,
    ['gh', 'run', 'list', '-R', slug, '--commit', sha, '-L', '20',
      '--json', 'status,conclusion,workflowName,url'],
    at,
  )
  if (runs === null) return null
  let parsed: Run[]
  try {
    parsed = JSON.parse(runs) as Run[]
  } catch {
    return null
  }
  const found = ciFromRuns(parsed)
  if (found.ci !== 'none') return found
  // No Actions runs: other CI (Vercel and the like) reports commit statuses.
  const status = await run(
    $,
    ['gh', 'api', `repos/${slug}/commits/${sha}/status`,
      '--jq', '[.state, .total_count] | @tsv'],
    at,
  )
  const [state, count] = (status ?? '').split('\t')
  if (!(Number(count) > 0)) return found
  const ci: CiState =
    state === 'success' ? 'success' : state === 'pending' ? 'pending' : 'failure'
  return { ci, name: 'commit status', url: `https://github.com/${slug}/commit/${sha}` }
}

async function refreshGit($: EngineInterface): Promise<void> {
  if (me.isGitBusy) {
    // Asked again mid-check (a push just landed): run once more after it.
    me.isGitDirty = true
    return
  }
  me.isGitBusy = true
  me.isGitDirty = false
  try {
    const repo = await $.session.repo().catch(() => null)
    if (repo === null) {
      me.git = null
      return
    }
    const at = await $.session.cwd().catch(() => me.cwd)
    const head = await run($, ['git', 'log', '-1', '--format=%H%x1f%h%x1f%s%x1f%cr'], at)
    if (head === null) {
      me.git = null
      return
    }
    const [sha = '', short = '', subject = '', when = ''] = head.split('\x1f')
    const branch = (await run($, ['git', 'rev-parse', '--abbrev-ref', 'HEAD'], at)) ?? '?'
    const upstream = await run($, ['git', 'rev-parse', '@{u}'], at)
    const ahead = Number((await run($, ['git', 'rev-list', '--count', '@{u}..HEAD'], at)) ?? 0)
    const slug = parseRepo(repo.remote)
    const git: GitStatus = {
      repo: slug,
      branch,
      sha,
      short,
      subject,
      when,
      ahead,
      ci: 'unknown',
      ciName: '',
      ciUrl: null,
      ciShort: (upstream ?? sha).slice(0, short.length || 7),
      checkedAt: await $.clock.now(),
    }
    if (slug !== null) {
      // CI only runs on what was pushed: check the upstream's commit.
      const found = await ciOf($, slug, upstream ?? sha, at)
      if (found === null) {
        git.error = 'gh недоступен или нет доступа к репозиторию'
      } else {
        git.ci = found.ci
        git.ciName = found.name
        git.ciUrl = found.url
      }
    }
    me.git = git
  } finally {
    me.isGitBusy = false
  }
  if (me.isGitDirty) await refreshGit($)
}

async function agents($: EngineInterface): Promise<AgentRow[]> {
  const list = await $.agent.list().catch(() => [])
  return list.map(a => {
    const step = agentSteps.get(a.id)
    return {
      id: a.id,
      label: a.name ?? (a.description || a.type),
      status: a.status,
      model: step?.model ?? null,
      effort: step?.effort ?? null,
    }
  })
}

async function readAll($: EngineInterface, now: number): Promise<SessionRecord[]> {
  const entries = await $.fs.list(me.dir).catch(() => [])
  const records: SessionRecord[] = []
  for (const entry of entries) {
    if (!entry.name.endsWith('.json') || now - entry.mtimeMs > KEEP_MS) continue
    const text = await $.fs.read(`${me.dir}/${entry.name}`).catch(() => null)
    if (text === null) continue
    try {
      records.push(JSON.parse(text) as SessionRecord)
    } catch {
      // A file caught mid-write is read again on the next heartbeat.
    }
  }
  return records.sort((a, b) => b.updatedAt - a.updatedAt)
}

// Publishes run one at a time, so an older snapshot never lands after a newer one.
function publish($: EngineInterface): Promise<void> {
  publishing = publishing.then(() => writeRecord($)).catch(() => undefined)
  return publishing
}

async function writeRecord($: EngineInterface): Promise<void> {
  if (me.id === '') return
  const now = await $.clock.now()
  const list = await agents($)
  const record: SessionRecord = {
    id: me.id,
    title: me.title,
    cwd: me.cwd,
    project: (me.git?.repo ?? me.cwd).split('/').pop() ?? me.cwd,
    activity: me.activity,
    since: me.since,
    model: me.model,
    effort: me.effort,
    agents: list,
    updatedAt: now,
    git: me.git,
  }
  await $.fs.write(`${me.dir}/${me.id}.json`, JSON.stringify(record)).catch(() => undefined)
  await update($, self, () => record)
  const records = await readAll($, now)
  await update($, all, () => records)
}

async function refreshAll($: EngineInterface): Promise<void> {
  await refreshGit($).catch(() => undefined)
  await publish($)
}

// After /clear the process lives on under a new session id with no
// session.start: follow it, so the new conversation gets its own record.
async function followId($: EngineInterface): Promise<void> {
  const id = await $.session.id().catch(() => me.id)
  if (id === me.id) return
  me.id = id
  me.title = ''
  me.activity = 'idle'
  me.since = await $.clock.now()
  asking.clear()
}

function openPane($: EngineInterface) {
  return $.ui.open({ id: PANE, title: PANE_TITLE })
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    const home = (await $.env.get('HOME')) ?? ''
    me.dir = `${home}/.claude/session-status`
    me.id = await $.session.id()
    me.cwd = await $.session.root()
    me.since = await $.clock.now()
    me.model = await $.session.model()
    me.effort = effortOf(await $.settings.read({ key: 'effortLevel' }).catch(() => undefined))
    const first = (await $.session.messages().catch(() => [])).find(m => m.role === 'user')
    me.title = firstLine(first?.text ?? '')

    await $.command.register({
      name: 'sessions',
      description: 'Панель всех сессий: статус, агенты, модель, CI на GitHub',
    })
    await $.command.register({
      name: 'session-band',
      description: 'Показать или скрыть строку статуса над полем ввода',
    })

    $.clock.every(HEARTBEAT_MS, () => fire(publish($)))
    $.clock.every(GIT_POLL_MS, () => fire(refreshAll($)))
    fire(refreshAll($))

    return started
  })

  on('session.end', async ($, e, next) => {
    me.activity = 'ended'
    me.since = await $.clock.now()
    asking.clear()
    await publish($)
    return next(e)
  })

  on('turn.start', async ($, e, next) => {
    if (e.agentId === undefined) {
      await followId($)
      me.activity = 'working'
      me.since = await $.clock.now()
      if (me.title === '') me.title = firstLine(e.text)
      fire(publish($))
    }
    return next(e)
  })

  on('turn.step', async function* ($, e, next) {
    const step = { model: e.model, effort: effortOf(e.effort) }
    if (e.agentId === undefined) {
      me.model = step.model
      me.effort = step.effort
    } else {
      agentSteps.set(e.agentId, step)
    }
    return yield* next(e)
  })

  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined) {
      me.activity = 'idle'
      me.since = await $.clock.now()
      asking.clear()
      fire(publish($))
      // A turn often ends with a commit or a push: look at GitHub again.
      $.clock.after(5000, () => fire(refreshAll($)))
    } else {
      fire(publish($))
    }
    return next(e)
  })

  // A permission prompt is open from an `ask` verdict until its call settles.
  // `$.tool.check` queries carry no tool_use_id and are left alone.
  on('tool.check', async ($, e, next) => {
    const verdict = await next(e)
    const isAsk = 'decision' in verdict && verdict.decision === 'ask'
    if (isAsk && e.tool_use_id !== undefined && me.activity !== 'ended') {
      asking.add(e.tool_use_id)
      me.activity = 'waiting'
      fire(publish($))
    }
    return verdict
  }).catch(($, e, next) => next(e))

  on('tool.call', async ($, e, next) => {
    try {
      return await next(e)
    } finally {
      if (asking.delete(e.tool_use_id) && asking.size === 0 && me.activity === 'waiting') {
        me.activity = 'working'
        fire(publish($))
      }
    }
  }).catch(($, e, next) => next(e))

  on('command.run', { command: 'sessions' }, async $ => {
    await openPane($)
    fire(refreshAll($))
    return { text: 'Панель «Сессии» открыта.' }
  })

  on('command.run', { command: 'session-band' }, async $ => {
    const hidden = await update($, isBandHidden, value => !value)
    return { text: hidden ? 'Строка статуса скрыта.' : 'Строка статуса показана.' }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const record = await read($, self)
    if (e.props.hasSurvey || record === null || (await read($, isBandHidden))) {
      return next(e)
    }
    const { Box, Button, Text } = $.ui.resolve(e)
    const now = await $.clock.now()

    return (
      <Box flexDirection="row" flexWrap="wrap" columnGap={1}>
        {activityText(Text, record, now)}
        <Text dimColor>·</Text>
        {modelText(Text, record)}
        {agentsText(Text, record)}
        {record.git !== null && <Text dimColor>·</Text>}
        {record.git !== null && gitText(Text, record.git)}
        <Button key="open" plain label="Все сессии" onPress={() => fire(openPane($))} />
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Button, Text, Link } = $.ui.resolve(e)
    const records = await read($, all)
    const now = await $.clock.now()

    const groups = new Map<string, SessionRecord[]>()
    for (const record of records) {
      const key = record.git?.repo ?? record.cwd
      groups.set(key, [...(groups.get(key) ?? []), record])
    }
    const working = records.filter(r => isLive(r, now) && r.activity !== 'idle').length

    return (
      <Box flexDirection="column" rowGap={1}>
        <Box flexDirection="row" columnGap={1} alignItems="center">
          <Text dimColor>
            {records.length === 0
              ? 'Пока нет сессий с этим плагином.'
              : `Сессий: ${records.length}, в работе: ${working}`}
          </Text>
          <Button key="refresh" plain label="Обновить" onPress={() => fire(refreshAll($))} />
        </Box>
        {[...groups.entries()].map(([key, list]) => {
          const git = list
            .map(r => r.git)
            .filter((g): g is GitStatus => g !== null)
            .sort((a, b) => b.checkedAt - a.checkedAt)[0]
          return (
            <Box key={key} flexDirection="column">
              <Text bold wrap="truncate-end">
                {git?.repo ?? list[0]?.project ?? key}
              </Text>
              {git !== undefined && (
                <Box flexDirection="row" columnGap={1} flexWrap="wrap">
                  {gitText(Text, git)}
                  {git.ciUrl !== null && <Link href={git.ciUrl} label="открыть сборку" />}
                </Box>
              )}
              {list.map(record => (
                <Box key={record.id} flexDirection="column" paddingLeft={2}>
                  <Box flexDirection="row" columnGap={1} flexWrap="wrap">
                    {activityText(Text, record, now)}
                    <Text dimColor>·</Text>
                    {modelText(Text, record)}
                    {agentsText(Text, record)}
                  </Box>
                  {record.title !== '' && (
                    <Text dimColor wrap="truncate-end">
                      {record.title}
                    </Text>
                  )}
                  {record.agents
                    .filter(a => ACTIVE_AGENT.has(a.status))
                    .map(a => (
                      <Text dimColor wrap="truncate-end">
                        {'  ↳ '}
                        {a.label}
                        {a.model !== null ? ` · ${prettyModel(a.model)}` : ''}
                        {a.effort !== null ? ` · ${a.effort}` : ''}
                      </Text>
                    ))}
                </Box>
              ))}
            </Box>
          )
        })}
      </Box>
    )
  })
}

type TextCtor = ReturnType<EngineInterface['ui']['resolve']>['Text']

function activityText(Text: TextCtor, record: SessionRecord, now: number) {
  if (!isLive(record, now)) {
    return <Text color="inactive">◌ закрыта · {ago(now - record.updatedAt)} назад</Text>
  }
  const time = ago(now - record.since)
  if (record.activity === 'working') return <Text color="claude">● работает {time}</Text>
  if (record.activity === 'waiting') {
    return <Text color="warning">◐ ждёт разрешения {time}</Text>
  }
  return <Text color="success">○ готов · {time}</Text>
}

function modelText(Text: TextCtor, record: SessionRecord) {
  const effort = record.effort === null ? '' : ` · ${record.effort}`
  return <Text>{`${prettyModel(record.model)}${effort}`}</Text>
}

function agentsText(Text: TextCtor, record: SessionRecord) {
  const active = record.agents.filter(a => ACTIVE_AGENT.has(a.status))
  if (active.length === 0) return null
  const models = new Map<string, number>()
  for (const a of active) {
    const name = a.model === null ? '?' : shortModel(a.model)
    models.set(name, (models.get(name) ?? 0) + 1)
  }
  const mix = [...models.entries()].map(([name, n]) => `${name}×${n}`).join(' ')
  return <Text color="suggestion">{`· агентов ${active.length} (${mix})`}</Text>
}

const CI_MARK: Record<CiState, { mark: string; color: string; label: string }> = {
  success: { mark: '✓', color: 'success', label: 'сборка прошла' },
  failure: { mark: '✗', color: 'error', label: 'сборка упала' },
  pending: { mark: '◷', color: 'warning', label: 'идёт сборка' },
  none: { mark: '–', color: 'inactive', label: 'нет сборки' },
  unknown: { mark: '?', color: 'inactive', label: 'CI неизвестен' },
}

function gitText(Text: TextCtor, git: GitStatus) {
  const ci = CI_MARK[git.ci]
  const unpushed = git.ahead > 0 ? ` · не запушено: ${git.ahead}` : ''
  const ciName = git.ciName !== '' && git.ci !== 'none' ? ` (${git.ciName})` : ''
  // With unpushed commits the build shown is the upstream's, not HEAD's.
  const ciOf = git.ahead > 0 && git.ciShort !== undefined ? ` для ${git.ciShort}` : ''
  return (
    <Text wrap="truncate-end">
      <Text dimColor>
        {`${git.branch} ${git.short} «${git.subject.slice(0, 50)}» ${git.when}${unpushed} `}
      </Text>
      <Text color={ci.color}>{`${ci.mark} ${ci.label}${ciOf}${ciName}`}</Text>
      {git.error !== undefined ? <Text color="warning">{` · ${git.error}`}</Text> : null}
    </Text>
  )
}
