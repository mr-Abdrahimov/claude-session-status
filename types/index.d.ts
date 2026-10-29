export type Activity = 'working' | 'waiting' | 'idle' | 'ended'

export type CiState = 'success' | 'failure' | 'pending' | 'none' | 'unknown'

export type GitStatus = {
  repo: string | null
  branch: string
  sha: string
  short: string
  subject: string
  when: string
  ahead: number
  // Files changed and not committed; absent in records of 0.2 and older.
  dirty?: number
  ci: CiState
  ciName: string
  ciUrl: string | null
  // The commit the CI result is for: the upstream's when HEAD is unpushed.
  ciShort?: string
  checkedAt: number
  error?: string
}

export type AgentRow = {
  id: string
  label: string
  status: string
  model: string | null
  effort: string | null
}

export type SessionRecord = {
  id: string
  // The desktop app's id of the chat (local_…); empty outside the app.
  appId?: string
  title: string
  cwd: string
  project: string
  activity: Activity
  since: number
  model: string
  effort: string | null
  agents: AgentRow[]
  updatedAt: number
  git: GitStatus | null
}

declare module 'claude-code' {
  interface PluginState {
    'session-status': {
      self: Shaped<SessionRecord | null>
      all: Shaped<SessionRecord[]>
      isBandHidden: boolean
      // "<HEAD sha>|<until, ms>": the commit offer is hidden for that commit
      // until then, after the person chose to wait.
      gitOfferPostponed: string
    }
  }
}
