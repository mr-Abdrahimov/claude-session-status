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
    }
  }
}
