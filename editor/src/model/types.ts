export type Scalar = string | number | boolean | null
export type JsonValue = Scalar | JsonValue[] | { [key: string]: JsonValue }

export type ActionGroup = 'inserts' | 'urls' | 'shortcuts' | 'scriptsShell' | 'scriptsAS'

export type ThemeChoice = 'system' | 'light' | 'dark'

export type StoreScenario = 'populated' | 'invalid' | 'conflict' | 'empty' | 'disconnected'

export interface Revision {
  generation: string
  version: number
  fingerprint: string
}

export interface Edit {
  path: string[]
  operation: 'set' | 'remove'
  value?: JsonValue
}

export interface EditRequest {
  expectedRevision: Revision
  edits: Edit[]
}

export interface DefaultsConfig {
  watch: string | null
  disableUpdateCheck: boolean | null
  muteNotifications: boolean | null
  activeAction: string | null
  icon: string | null
  moveTo: string | null
  simEsc: boolean | null
  simKeypress: boolean | null
  smartCasing: boolean | null
  smartPunctuation: boolean | null
  smartSpacing: boolean | null
  actionDelay: number | null
  history: number | null
  simReturn: boolean | null
  returnDelay: number | null
  restoreClipboard: boolean | null
  restoreClipboardDelay: number | null
  scheduledActionTimeout: number | null
  scriptAsync: boolean | null
  scriptWaitTimeout: number | null
  clipboardStacking: boolean | null
  clipboardAttachments: boolean | null
  clipboardBuffer: number | null
  clipboardIgnore: string | null
  bypassModes: string | null
  muteTriggers: boolean | null
  autoUpdateConfig: boolean | null
  redactedLogs: boolean | null
  nextAction: string | null

  // The runtime still accepts legacy and future fields. They are retained in
  // snapshots so a fixture edit never silently drops data that the editor
  // does not expose.
  [key: string]: JsonValue | undefined
}

export interface InsertConfig {
  action: string
  icon?: string | null
  moveTo?: string | null
  simEsc?: boolean | null
  simKeypress?: boolean | null
  smartCasing?: boolean | null
  smartPunctuation?: boolean | null
  smartSpacing?: boolean | null
  actionDelay?: number | null
  simReturn?: boolean | null
  restoreClipboard?: boolean | null
  restoreClipboardDelay?: number | null
  clipboardStacking?: boolean | null
  clipboardAttachments?: boolean | null
  inputCondition?: string | null
  nextAction?: string | null
  triggerVoice?: string | null
  triggerApps?: string | null
  triggerModes?: string | null
  triggerUrls?: string | null
  triggerLogic?: string | null
  scriptAsync?: boolean | null
  scriptWaitTimeout?: number | null
  openWith?: string | null
  openBackground?: boolean | null

  // Action groups may contain fields from a newer Macrowhisper schema. The
  // fixture preserves those fields, but the mutation API treats them as
  // read-only until the editor has an explicit schema projection for them.
  [key: string]: JsonValue | undefined
}

export type ActionConfig = InsertConfig

export interface ConfigSnapshot {
  revision: Revision
  path: string
  defaults: DefaultsConfig
  inserts: Record<string, InsertConfig>
  urls: Record<string, ActionConfig>
  shortcuts: Record<string, ActionConfig>
  scriptsShell: Record<string, ActionConfig>
  scriptsAS: Record<string, ActionConfig>
  disk: {
    status: 'valid' | 'invalid' | 'empty' | 'unavailable'
    message?: string
  }
  runtime: {
    status: 'connected' | 'fallback' | 'disconnected' | 'loading'
    message: string
  }
  /** Fields retained from the source configuration but not editable here. */
  readOnly?: ReadOnlyField[]
}

export interface ReadOnlyField {
  path: string[]
  reason: string
}

export interface MutationResult {
  snapshot: ConfigSnapshot
  request: EditRequest
}

export type FolderPickerPurpose = 'watch' | 'moveTo'

/**
 * The store contract shared by the live HTTP adapter and the in-memory
 * fixture. Optional capabilities keep native and fixture-only behavior honest
 * while both adapters implement the core editor operations below.
 */
export interface EditorStore {
  getSnapshot(): ConfigSnapshot
  subscribe(listener: StoreListener): () => void
  request(edits: Edit[]): EditRequest
  mutate(request: EditRequest): Promise<MutationResult>
  createInsert(name: string, action: InsertConfig): Promise<MutationResult>
  duplicateInsert(sourceName: string, targetName: string): Promise<MutationResult>
  renameInsert(sourceName: string, targetName: string): Promise<MutationResult>
  deleteInsert(name: string): Promise<MutationResult>
  /** Present the daemon-owned macOS directory picker when the live bridge is available. */
  chooseDirectory?(purpose: FolderPickerPurpose): Promise<string | null>

  getScenario?(): StoreScenario
  setScenario?(scenario: StoreScenario): void
  reconnect?(): ConfigSnapshot
  simulateExternalChange?(change?: FixtureExternalChange): ConfigSnapshot
  externalChange?(change?: FixtureExternalChange): ConfigSnapshot
  setPersistenceFailure?(enabled: boolean, message?: string): void
  setFailWrites?(enabled: boolean, message?: string): void
}

export type EditorErrorCode = 'disconnected' | 'conflict' | 'stale' | 'validation' | 'persistence'

export class EditorStoreError extends Error {
  readonly code: EditorErrorCode
  readonly path: string[]
  readonly request?: EditRequest

  constructor(code: EditorErrorCode, message: string, path: string[] = [], request?: EditRequest) {
    super(message)
    this.name = 'EditorStoreError'
    this.code = code
    this.path = path
    this.request = request
  }
}

export type StoreListener = (snapshot: ConfigSnapshot) => void

/** Options for the in-memory adapter; these model transport and persistence
 * behavior without connecting to a daemon or touching a live config file. */
export interface FixtureStoreOptions {
  /** Initial fixture scenario when the options-only constructor is used. */
  scenario?: StoreScenario
  /** Delay each accepted/rejected write by this many milliseconds. */
  writeDelayMs?: number
  /** Alias for writeDelayMs for callers that think in transport latency. */
  latencyMs?: number
  /** Make every write fail with a persistence error until cleared. */
  persistenceFailure?: boolean
  /** Alias for persistenceFailure. */
  failWrites?: boolean
  /** Message used for simulated persistence failures. */
  failureMessage?: string
}

/** A structured external edit used by the in-memory watcher fixture. */
export type FixtureExternalChange =
  | Edit
  | Edit[]
  | ((snapshot: ConfigSnapshot) => void)

export interface ActionListItem {
  name: string
  group: ActionGroup
  action: InsertConfig
  source: 'custom' | 'inherited' | 'template' | 'invalid'
}

export interface FieldMetadata {
  key: string
  label: string
  group: string
  description: string
  type: 'text' | 'number' | 'boolean' | 'choice'
  unit?: string
  defaultValue?: Scalar
  editable: boolean
  unsupportedReason?: string
}

export interface ScenarioDefinition {
  id: StoreScenario
  label: string
  detail: string
}

export function isEditorStoreError(error: unknown, code?: EditorErrorCode): error is EditorStoreError {
  return error instanceof EditorStoreError && (code === undefined || error.code === code)
}
