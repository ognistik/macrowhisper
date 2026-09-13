import type {
  ActionConfig,
  ActionGroup,
  ConfigSnapshot,
  DefaultsConfig,
  Edit,
  EditRequest,
  EditorStore,
  InsertConfig,
  JsonValue,
  MutationResult,
  ReadOnlyField,
  Revision,
  StoreListener,
} from '../model/types'
import { EditorStoreError } from '../model/types'

export const API_SESSION_STORAGE_KEY = 'macrowhisper-editor-session'
/** Descriptive alias for embedders that do not need the API prefix. */
export const SESSION_STORAGE_KEY = API_SESSION_STORAGE_KEY
export const BOOTSTRAP_HEADER = 'X-Macrowhisper-Bootstrap'

const actionGroups: ActionGroup[] = ['inserts', 'urls', 'shortcuts', 'scriptsShell', 'scriptsAS']
const unavailableRevision: Revision = {
  generation: 'unavailable',
  version: 0,
  fingerprint: 'unavailable',
}

type SessionExpiry = string | number | null

interface StoredSession {
  sessionToken: string
  expiresAt?: SessionExpiry
}

interface ApiDiskIssue {
  path?: unknown
  message?: unknown
  kind?: unknown
  rawValue?: unknown
}

interface ApiErrorPayload {
  code?: unknown
  path?: unknown
  message?: unknown
  issues?: unknown
}

export interface ApiStoreOptions {
  /** Base URL for the daemon. Empty means same-origin relative API paths. */
  baseUrl?: string
  /** Injectable fetch implementation for tests and non-window consumers. */
  fetch?: typeof globalThis.fetch
  /** Alias retained for callers that prefer an explicit implementation name. */
  fetchImpl?: typeof globalThis.fetch
  /** Tab-scoped storage. No localStorage or cookie fallback is used. */
  sessionStorage?: Storage | null
  /** Alias for sessionStorage for consumers with a generic storage wrapper. */
  storage?: Storage | null
  /** Polling interval. Set to 0 to disable polling. */
  pollIntervalMs?: number
  /** Alias for pollIntervalMs. */
  pollInterval?: number
  /** Start authentication and the initial snapshot load in the constructor. */
  autoStart?: boolean
  /** Explicit bootstrap token, primarily useful for embedding the editor. */
  bootstrapToken?: string | null
  /** Storage key override for an application embedding the editor. */
  storageKey?: string
  /** Browser location/history seams used by tests. */
  location?: Pick<Location, 'hash' | 'href' | 'pathname' | 'search'>
  history?: Pick<History, 'replaceState'>
}

interface ResponseLike {
  ok: boolean
  status: number
  statusText?: string
  json?: () => Promise<unknown>
  text?: () => Promise<string>
}

function isRecord(value: unknown): value is Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return false
  const prototype = Object.getPrototypeOf(value)
  return prototype === Object.prototype || prototype === null
}

function hasOwn(value: object, key: PropertyKey): boolean {
  return Object.prototype.hasOwnProperty.call(value, key)
}

function cloneValue<T>(value: T): T {
  if (typeof structuredClone === 'function') return structuredClone(value)
  return JSON.parse(JSON.stringify(value)) as T
}

function revisionRank(revision: Revision, current: Revision): number {
  if (revision.generation !== current.generation) return 1
  if (revision.version > current.version) return 1
  if (revision.version < current.version) return -1
  if (revision.fingerprint === current.fingerprint) return 0
  // A manager revision should change its version with its fingerprint. If a
  // proxy returns an inconsistent pair, accepting the fresh response is less
  // surprising than retaining a stale disk status.
  return 1
}

function initialSnapshot(status: 'loading' | 'disconnected', message: string): ConfigSnapshot {
  return {
    revision: cloneValue(unavailableRevision),
    path: '',
    defaults: {} as DefaultsConfig,
    inserts: {},
    urls: {},
    shortcuts: {},
    scriptsShell: {},
    scriptsAS: {},
    disk: { status: 'unavailable', message },
    runtime: { status, message },
  }
}

function responseHeaderValue(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() !== '' ? value : undefined
}

function parseRevision(value: unknown): Revision {
  if (!isRecord(value)) throw new Error('The configuration response has no revision.')
  const generation = responseHeaderValue(value.generation)
  const fingerprint = responseHeaderValue(value.fingerprint)
  const version = value.version
  if (
    generation === undefined
    || fingerprint === undefined
    || typeof version !== 'number'
    || !Number.isFinite(version)
    || !Number.isInteger(version)
    || version < 0
  ) {
    throw new Error('The configuration response has an invalid revision.')
  }
  return { generation, version, fingerprint }
}

function mapActionGroup(config: Record<string, unknown>, group: ActionGroup): Record<string, ActionConfig> {
  const value = config[group]
  if (!isRecord(value)) return {}
  return cloneValue(value) as Record<string, ActionConfig>
}

function mapDefaults(config: Record<string, unknown>): DefaultsConfig {
  const value = config.defaults
  if (!isRecord(value)) return {} as DefaultsConfig
  // Do not fill defaults here. The daemon has already applied its canonical
  // decoding semantics, and an absent/nullable/empty value is meaningful to
  // the editor.
  return cloneValue(value) as DefaultsConfig
}

function issueMessage(issue: ApiDiskIssue): string | undefined {
  return typeof issue.message === 'string' && issue.message.trim() !== '' ? issue.message : undefined
}

function mapDiskIssues(value: unknown): ApiDiskIssue[] {
  if (!Array.isArray(value)) return []
  return value.filter(isRecord).map((issue) => ({
    path: issue.path,
    message: issue.message,
    kind: issue.kind,
    rawValue: issue.rawValue,
  }))
}

function readOnlyForLegacy(isLegacyOnDisk: boolean): ReadOnlyField[] | undefined {
  if (!isLegacyOnDisk) return undefined
  return [{ path: [], reason: 'This legacy configuration must be migrated before it can be edited here.' }]
}

/**
 * Convert the daemon's Codable ConfigurationSnapshot into the shape consumed
 * by the existing editor. This function intentionally copies values without
 * truthiness checks so null, false, 0, and empty strings survive a round trip.
 */
export function mapConfigurationSnapshot(payload: unknown): ConfigSnapshot {
  if (!isRecord(payload) || !isRecord(payload.config)) {
    throw new Error('The configuration response is malformed.')
  }

  let revision: Revision
  try {
    revision = parseRevision(payload.revision)
  } catch (error) {
    throw new Error(error instanceof Error ? error.message : 'The configuration response has an invalid revision.')
  }

  if (typeof payload.configPath !== 'string') throw new Error('The configuration response has no config path.')
  if (typeof payload.diskIsValid !== 'boolean') throw new Error('The configuration response has no disk validity.')
  if (typeof payload.isLegacyOnDisk !== 'boolean') throw new Error('The configuration response has no legacy state.')

  const issues = mapDiskIssues(payload.diskIssues)
  const issueMessages = issues.map(issueMessage).filter((message): message is string => message !== undefined)
  const diskMessage = issueMessages.length > 0 ? issueMessages.join(' ') : undefined
  const diskStatus = payload.diskIsValid ? 'valid' : 'invalid'
  const runtimeStatus = payload.diskIsValid ? 'connected' : 'fallback'
  const runtimeMessage = payload.diskIsValid
    ? payload.isLegacyOnDisk
      ? 'Connected to Macrowhisper. This legacy configuration is read-only until migration.'
      : 'Connected to Macrowhisper.'
    : 'Runtime is using fallback defaults while the configuration file is invalid.'

  const config = payload.config
  const snapshot: ConfigSnapshot = {
    revision,
    path: payload.configPath,
    defaults: mapDefaults(config),
    inserts: mapActionGroup(config, 'inserts') as Record<string, InsertConfig>,
    urls: mapActionGroup(config, 'urls'),
    shortcuts: mapActionGroup(config, 'shortcuts'),
    scriptsShell: mapActionGroup(config, 'scriptsShell'),
    scriptsAS: mapActionGroup(config, 'scriptsAS'),
    disk: { status: diskStatus, ...(diskMessage ? { message: diskMessage } : {}) },
    runtime: { status: runtimeStatus, message: runtimeMessage },
  }
  const readOnly = readOnlyForLegacy(payload.isLegacyOnDisk)
  if (readOnly) snapshot.readOnly = readOnly
  return snapshot
}

function extractBootstrapToken(hash: string | undefined): string | undefined {
  if (!hash) return undefined
  const fragment = hash.startsWith('#') ? hash.slice(1) : hash
  if (!fragment) return undefined

  // The CLI currently emits a named parameter. Accept a few descriptive
  // aliases so a packaged bootstrap page can evolve without breaking an older
  // editor bundle; a bare fragment remains useful for local embedding.
  const params = new URLSearchParams(fragment)
  for (const key of ['bootstrap', 'bootstrapToken', 'token', 'macrowhisperBootstrap']) {
    const token = params.get(key)
    if (token) return token
  }
  if (!fragment.includes('=') && !fragment.startsWith('/')) return decodeURIComponent(fragment)
  return undefined
}

function cleanBootstrapFragment(
  location: Pick<Location, 'hash' | 'href' | 'pathname' | 'search'> | undefined,
  history: Pick<History, 'replaceState'> | undefined,
): void {
  if (!location || !history) return
  const href = typeof location.href === 'string' ? location.href : ''
  const cleanHref = href.includes('#')
    ? href.slice(0, href.indexOf('#'))
    : `${location.pathname}${location.search}`
  try {
    history.replaceState(null, '', cleanHref)
  } catch {
    // A test seam or an embedded document may reject an absolute URL. The
    // relative path is still sufficient to remove the secret fragment.
    try {
      history.replaceState(null, '', `${location.pathname}${location.search}`)
    } catch {
      // Browsers that disallow history mutation leave the token in the
      // address bar, but it is never sent to the API as a query parameter.
    }
  }
}

function defaultLocation(): Pick<Location, 'hash' | 'href' | 'pathname' | 'search'> | undefined {
  if (typeof window === 'undefined') return undefined
  return window.location
}

function defaultHistory(): Pick<History, 'replaceState'> | undefined {
  if (typeof window === 'undefined') return undefined
  return window.history
}

function defaultStorage(): Storage | null {
  try {
    return typeof window !== 'undefined' ? window.sessionStorage : null
  } catch {
    return null
  }
}

function parseExpiry(value: unknown): SessionExpiry {
  if (typeof value === 'string' || typeof value === 'number') return value
  return null
}

function expiryMilliseconds(value: SessionExpiry): number | undefined {
  if (value === null) return undefined
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) return undefined
    // Unix timestamps are conventionally seconds; JavaScript dates use ms.
    return value < 10_000_000_000 ? value * 1000 : value
  }
  const parsed = Date.parse(value)
  return Number.isFinite(parsed) ? parsed : undefined
}

function isExpired(value: SessionExpiry): boolean {
  const milliseconds = expiryMilliseconds(value)
  return milliseconds !== undefined && milliseconds <= Date.now()
}

function parseStoredSession(value: string | null): StoredSession | undefined {
  if (!value) return undefined
  try {
    const parsed: unknown = JSON.parse(value)
    if (isRecord(parsed) && typeof parsed.sessionToken === 'string' && parsed.sessionToken !== '') {
      return { sessionToken: parsed.sessionToken, expiresAt: parseExpiry(parsed.expiresAt) }
    }
  } catch {
    // Older versions may have stored only the opaque bearer token.
  }
  return value.trim() === '' ? undefined : { sessionToken: value }
}

function readStoredSession(storage: Storage | null, key: string): StoredSession | undefined {
  if (!storage) return undefined
  try {
    const session = parseStoredSession(storage.getItem(key))
    if (!session) return undefined
    if (isExpired(session.expiresAt ?? null)) {
      try { storage.removeItem(key) } catch { /* private storage can be unavailable */ }
      return undefined
    }
    return session
  } catch {
    return undefined
  }
}

function serverErrorCode(payload: unknown): string | undefined {
  if (!isRecord(payload)) return undefined
  const candidate = isRecord(payload.error) ? payload.error.code : payload.code
  return typeof candidate === 'string' ? candidate : undefined
}

function serverErrorDetails(payload: unknown): ApiErrorPayload {
  if (!isRecord(payload)) return {}
  const source = isRecord(payload.error) ? payload.error : payload
  return {
    code: source.code,
    path: source.path,
    message: source.message,
    issues: source.issues,
  }
}

const errorCodeMap: Record<string, 'validation' | 'stale' | 'persistence' | 'disconnected'> = {
  malformedEdit: 'validation',
  invalidPath: 'validation',
  typeMismatch: 'validation',
  outOfRange: 'validation',
  validationFailed: 'validation',
  unknownKey: 'validation',
  unsupportedVersion: 'validation',
  staleRevision: 'stale',
  resourceMismatch: 'stale',
  invalidDiskState: 'validation',
  legacyConfiguration: 'validation',
  persistenceFailed: 'persistence',
  encodingFailed: 'persistence',
}

function mappedErrorCode(code: string | undefined, status: number): 'validation' | 'stale' | 'persistence' | 'disconnected' {
  if (code && errorCodeMap[code]) return errorCodeMap[code]
  if (status === 401 || status === 403) return 'disconnected'
  if (status === 408 || status === 429 || status === 502 || status === 503 || status === 504) return 'disconnected'
  if (status === 409) return 'stale'
  if (status === 400 || status === 404 || status === 405 || status === 415 || status === 422) return 'validation'
  if (status >= 500) return 'persistence'
  return 'disconnected'
}

function errorPath(value: unknown): string[] {
  return Array.isArray(value) && value.every((part) => typeof part === 'string')
    ? cloneValue(value) as string[]
    : []
}

function errorMessage(details: ApiErrorPayload, response: ResponseLike): string {
  if (typeof details.message === 'string' && details.message.trim() !== '') return details.message
  if (response.status === 401 || response.status === 403) return 'The editor session has expired. Open a fresh editor link to reconnect.'
  if (response.status >= 500) return 'Macrowhisper could not persist this configuration.'
  if (response.status === 409) return 'This configuration changed elsewhere. Reload before applying the edit.'
  return response.statusText ? `The editor request failed (${response.statusText}).` : 'The editor request failed.'
}

async function responseBody(response: ResponseLike): Promise<unknown> {
  if (typeof response.json === 'function') {
    try { return await response.json() } catch { /* fall through to text */ }
  }
  if (typeof response.text === 'function') {
    try {
      const text = await response.text()
      if (text.trim() !== '') return JSON.parse(text) as unknown
    } catch {
      // Non-JSON error bodies are mapped from their HTTP status below.
    }
  }
  return undefined
}

export class ApiStore implements EditorStore {
  private readonly listeners = new Set<StoreListener>()
  private readonly fetchImpl: typeof globalThis.fetch
  private readonly baseUrl: string
  private readonly storage: Storage | null
  private readonly storageKey: string
  private readonly pollIntervalMs: number
  private snapshot: ConfigSnapshot
  private sessionToken: string | null = null
  private sessionExpiresAt: SessionExpiry = null
  private bootstrapToken: string | undefined
  private mutationQueue: Promise<unknown> = Promise.resolve()
  private startPromise: Promise<ConfigSnapshot> | null = null
  private started = false
  private disposed = false
  private pollTimer: ReturnType<typeof setTimeout> | null = null
  private polling = false

  constructor(options: ApiStoreOptions = {}) {
    const browserLocation = options.location ?? defaultLocation()
    const browserHistory = options.history ?? defaultHistory()
    this.baseUrl = options.baseUrl ?? ''
    this.fetchImpl = options.fetchImpl ?? options.fetch ?? globalThis.fetch.bind(globalThis)
    this.storage = options.sessionStorage === undefined
      ? options.storage === undefined ? defaultStorage() : options.storage
      : options.sessionStorage
    this.storageKey = options.storageKey ?? API_SESSION_STORAGE_KEY
    this.pollIntervalMs = Math.max(0, options.pollIntervalMs ?? options.pollInterval ?? 5000)

    this.bootstrapToken = options.bootstrapToken ?? extractBootstrapToken(browserLocation?.hash)
    if (this.bootstrapToken) cleanBootstrapFragment(browserLocation, browserHistory)

    const stored = this.bootstrapToken ? undefined : readStoredSession(this.storage, this.storageKey)
    if (stored) {
      this.sessionToken = stored.sessionToken
      this.sessionExpiresAt = stored.expiresAt ?? null
    }
    const hasCredential = this.bootstrapToken !== undefined || this.sessionToken !== null
    this.snapshot = initialSnapshot(
      hasCredential ? 'loading' : 'disconnected',
      hasCredential
        ? 'Connecting to the local Macrowhisper editor…'
        : 'No active Macrowhisper editor session. Open a fresh editor link to connect.',
    )

    if (options.autoStart !== false) void this.start()
  }

  getSnapshot(): ConfigSnapshot {
    return cloneValue(this.snapshot)
  }

  subscribe(listener: StoreListener): () => void {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  request(edits: Edit[]): EditRequest {
    return {
      expectedRevision: cloneValue(this.snapshot.revision),
      edits: cloneValue(edits),
    }
  }

  /** Start authentication, load the first snapshot, and begin polling. */
  start(): Promise<ConfigSnapshot> {
    if (this.disposed) {
      return Promise.reject(new EditorStoreError('disconnected', 'The editor store has been disposed.'))
    }
    if (this.startPromise) return this.startPromise
    this.started = true
    this.startPromise = this.initialize()
      .catch((error: unknown) => {
        this.markDisconnected(error instanceof Error ? error.message : 'The editor could not connect.')
        return this.getSnapshot()
      })
      .then((snapshot) => {
        if (!this.disposed && this.sessionToken && this.pollIntervalMs > 0) this.schedulePoll()
        return snapshot
      })
    return this.startPromise
  }

  /** Stop polling and ignore any response that completes after disposal. */
  dispose(): void {
    this.disposed = true
    if (this.pollTimer !== null) {
      clearTimeout(this.pollTimer)
      this.pollTimer = null
    }
  }

  /** Fetch and publish the current daemon snapshot on demand. */
  async refresh(): Promise<ConfigSnapshot> {
    await this.start()
    if (!this.sessionToken) throw new EditorStoreError('disconnected', 'The editor is not connected.')
    return this.fetchSnapshot(true)
  }

  async mutate(request: EditRequest): Promise<MutationResult> {
    let queuedRequest: EditRequest
    try {
      queuedRequest = cloneValue(request)
    } catch {
      return Promise.reject(new EditorStoreError('validation', 'A mutation must contain JSON-compatible values.'))
    }

    const operation = async (): Promise<MutationResult> => {
      await this.start()
      if (this.disposed) throw new EditorStoreError('disconnected', 'The editor store has been disposed.', [], queuedRequest)
      if (!this.sessionToken) {
        throw new EditorStoreError('disconnected', 'The editor is not connected. Open a fresh editor link to retry.', [], queuedRequest)
      }
      return this.submitMutation(queuedRequest)
    }
    const queued = this.mutationQueue.then(operation, operation)
    // A failed request must not poison later writes in this tab.
    this.mutationQueue = queued.then(() => undefined, () => undefined)
    return queued
  }

  createInsert(name: string, action: InsertConfig): Promise<MutationResult> {
    const cleanName = name.trim()
    if (!cleanName) return Promise.reject(new EditorStoreError('validation', 'Give the Insert a name.', ['inserts']))
    if (this.hasActionName(cleanName)) {
      return Promise.reject(new EditorStoreError('validation', 'Action names must be unique across every action group.', ['inserts', cleanName]))
    }
    return this.mutate(this.request([
      { path: ['inserts', cleanName], operation: 'set', value: cloneValue(action) as unknown as JsonValue },
    ]))
  }

  duplicateInsert(sourceName: string, targetName: string): Promise<MutationResult> {
    const cleanName = targetName.trim()
    const source = this.getAction('inserts', sourceName)
    if (!source) return Promise.reject(new EditorStoreError('validation', 'The source Insert is unavailable.', ['inserts', sourceName]))
    if (!cleanName) return Promise.reject(new EditorStoreError('validation', 'Give the duplicate a name.', ['inserts']))
    if (this.hasActionName(cleanName)) {
      return Promise.reject(new EditorStoreError('validation', 'Action names must be unique across every action group.', ['inserts', cleanName]))
    }
    return this.mutate(this.request([
      { path: ['inserts', cleanName], operation: 'set', value: cloneValue(source) as unknown as JsonValue },
    ]))
  }

  renameInsert(sourceName: string, targetName: string): Promise<MutationResult> {
    const cleanName = targetName.trim()
    const source = this.getAction('inserts', sourceName)
    if (!source) return Promise.reject(new EditorStoreError('validation', 'The source Insert is unavailable.', ['inserts', sourceName]))
    if (!cleanName) return Promise.reject(new EditorStoreError('validation', 'Give the Insert a name.', ['inserts', sourceName]))
    if (sourceName === cleanName) {
      return Promise.resolve({
        snapshot: this.getSnapshot(),
        request: { expectedRevision: cloneValue(this.snapshot.revision), edits: [] },
      })
    }
    if (this.hasActionName(cleanName)) {
      return Promise.reject(new EditorStoreError('validation', 'Action names must be unique across every action group.', ['inserts', cleanName]))
    }

    const edits: Edit[] = [{
      path: ['inserts', cleanName],
      operation: 'set',
      value: cloneValue(source) as unknown as JsonValue,
    }]
    for (const group of actionGroups) {
      const actions = this.snapshot[group]
      for (const name of Object.keys(actions)) {
        const action = actions[name]
        if (!isRecord(action) || typeof action.nextAction !== 'string' || action.nextAction.trim() !== sourceName) continue
        const destinationName = group === 'inserts' && name === sourceName ? cleanName : name
        edits.push({ path: [group, destinationName, 'nextAction'], operation: 'set', value: cleanName })
      }
    }
    if (typeof this.snapshot.defaults.activeAction === 'string' && this.snapshot.defaults.activeAction.trim() === sourceName) {
      edits.push({ path: ['defaults', 'activeAction'], operation: 'set', value: cleanName })
    }
    if (typeof this.snapshot.defaults.nextAction === 'string' && this.snapshot.defaults.nextAction.trim() === sourceName) {
      edits.push({ path: ['defaults', 'nextAction'], operation: 'set', value: cleanName })
    }
    edits.push({ path: ['inserts', sourceName], operation: 'remove' })
    return this.mutate(this.request(edits))
  }

  deleteInsert(name: string): Promise<MutationResult> {
    if (!this.getAction('inserts', name)) {
      return Promise.reject(new EditorStoreError('validation', 'The Insert is no longer available.', ['inserts', name]))
    }
    const inbound = this.inboundReferences(name)
    if (inbound.length > 0) {
      return Promise.reject(new EditorStoreError('validation', `This Insert is referenced by ${inbound.join(', ')}. Change those links before deleting it.`, ['inserts', name]))
    }
    return this.mutate(this.request([{ path: ['inserts', name], operation: 'remove' }]))
  }

  private async initialize(): Promise<ConfigSnapshot> {
    if (this.bootstrapToken) {
      const token = this.bootstrapToken
      this.bootstrapToken = undefined
      await this.exchangeBootstrapToken(token)
    }
    if (!this.sessionToken) {
      this.markDisconnected('No active Macrowhisper editor session. Open a fresh editor link to connect.')
      return this.getSnapshot()
    }
    return this.fetchSnapshot(true)
  }

  private endpoint(path: string): string {
    if (!this.baseUrl) return path
    return `${this.baseUrl.replace(/\/$/, '')}${path}`
  }

  private async exchangeBootstrapToken(token: string): Promise<void> {
    let response: ResponseLike
    try {
      response = await this.fetchImpl(this.endpoint('/api/session'), {
        method: 'POST',
        headers: {
          Accept: 'application/json',
          [BOOTSTRAP_HEADER]: token,
        },
        cache: 'no-store',
      }) as ResponseLike
    } catch {
      throw new EditorStoreError('disconnected', 'The local Macrowhisper editor could not be reached.')
    }
    if (!response.ok) throw await this.responseError(response)
    const body = await responseBody(response)
    if (!isRecord(body) || typeof body.sessionToken !== 'string' || body.sessionToken === '') {
      throw new EditorStoreError('disconnected', 'The local Macrowhisper session response was malformed.')
    }
    this.sessionToken = body.sessionToken
    this.sessionExpiresAt = parseExpiry(body.expiresAt)
    this.persistSession()
  }

  private async fetchSnapshot(publish: boolean): Promise<ConfigSnapshot> {
    if (!this.sessionToken) throw new EditorStoreError('disconnected', 'The editor is not connected.')
    let response: ResponseLike
    try {
      response = await this.fetchImpl(this.endpoint('/api/config'), {
        method: 'GET',
        headers: {
          Accept: 'application/json',
          Authorization: `Bearer ${this.sessionToken}`,
        },
        cache: 'no-store',
      }) as ResponseLike
    } catch {
      throw new EditorStoreError('disconnected', 'The local Macrowhisper editor could not be reached.')
    }
    if (!response.ok) throw await this.responseError(response)
    const body = await responseBody(response)
    let mapped: ConfigSnapshot
    try {
      mapped = mapConfigurationSnapshot(body)
    } catch (error) {
      throw new EditorStoreError('persistence', error instanceof Error ? error.message : 'The configuration response was malformed.')
    }
    if (publish && !this.disposed) this.publishSnapshot(mapped)
    return mapped
  }

  private async submitMutation(request: EditRequest): Promise<MutationResult> {
    let response: ResponseLike
    try {
      response = await this.fetchImpl(this.endpoint('/api/config/edits'), {
        method: 'POST',
        headers: {
          Accept: 'application/json',
          Authorization: `Bearer ${this.sessionToken ?? ''}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          expectedRevision: cloneValue(request.expectedRevision),
          edits: cloneValue(request.edits),
        }),
        cache: 'no-store',
      }) as ResponseLike
    } catch {
      throw new EditorStoreError('disconnected', 'The local Macrowhisper editor could not be reached.', [], request)
    }
    if (!response.ok) throw await this.responseError(response, request)
    const body = await responseBody(response)
    let snapshot: ConfigSnapshot
    try {
      snapshot = mapConfigurationSnapshot(body)
    } catch (error) {
      throw new EditorStoreError('persistence', error instanceof Error ? error.message : 'The configuration response was malformed.', [], request)
    }
    if (!this.disposed) this.publishSnapshot(snapshot)
    return { snapshot, request: cloneValue(request) }
  }

  private async responseError(response: ResponseLike, request?: EditRequest): Promise<EditorStoreError> {
    const body = await responseBody(response)
    const details = serverErrorDetails(body)
    const code = serverErrorCode(body)
    const mapped = mappedErrorCode(code, response.status)
    if (mapped === 'disconnected' && (response.status === 401 || response.status === 403)) this.clearSession()
    return new EditorStoreError(mapped, errorMessage(details, response), errorPath(details.path), request)
  }

  private persistSession(): void {
    if (!this.storage || !this.sessionToken) return
    try {
      const value: StoredSession = {
        sessionToken: this.sessionToken,
        ...(this.sessionExpiresAt === null ? {} : { expiresAt: this.sessionExpiresAt }),
      }
      this.storage.setItem(this.storageKey, JSON.stringify(value))
    } catch {
      // A privacy-mode storage failure does not prevent the in-memory session.
    }
  }

  private clearSession(): void {
    this.sessionToken = null
    this.sessionExpiresAt = null
    if (!this.storage) return
    try { this.storage.removeItem(this.storageKey) } catch { /* storage is optional */ }
  }

  private publishSnapshot(next: ConfigSnapshot): void {
    if (this.disposed) return
    this.snapshot = cloneValue(next)
    const emitted = this.getSnapshot()
    for (const listener of this.listeners) {
      try { listener(emitted) } catch { /* observer failures cannot undo a commit */ }
    }
  }

  private markDisconnected(message: string): void {
    if (this.disposed) return
    const next = cloneValue(this.snapshot)
    next.runtime = { status: 'disconnected', message }
    if (next.disk.status === 'unavailable') next.disk = { status: 'unavailable', message }
    this.publishSnapshot(next)
  }

  private hasActionName(name: string): boolean {
    return actionGroups.some((group) => hasOwn(this.snapshot[group], name))
  }

  private getAction(group: ActionGroup, name: string): InsertConfig | undefined {
    const actions = this.snapshot[group]
    return hasOwn(actions, name) ? actions[name] : undefined
  }

  private inboundReferences(name: string): string[] {
    const inbound: string[] = []
    if (typeof this.snapshot.defaults.activeAction === 'string' && this.snapshot.defaults.activeAction.trim() === name) inbound.push('defaults.activeAction')
    if (typeof this.snapshot.defaults.nextAction === 'string' && this.snapshot.defaults.nextAction.trim() === name) inbound.push('defaults.nextAction')
    for (const group of actionGroups) {
      for (const actionName of Object.keys(this.snapshot[group])) {
        const action = this.snapshot[group][actionName]
        if (isRecord(action) && typeof action.nextAction === 'string' && action.nextAction.trim() === name) inbound.push(`${group}.${actionName}.nextAction`)
      }
    }
    return inbound
  }

  private schedulePoll(): void {
    if (this.disposed || !this.started || !this.sessionToken || this.pollIntervalMs <= 0) return
    if (this.pollTimer !== null) clearTimeout(this.pollTimer)
    this.pollTimer = setTimeout(() => {
      this.pollTimer = null
      void this.pollOnce()
    }, this.pollIntervalMs)
  }

  private async pollOnce(): Promise<void> {
    if (this.disposed || this.polling || !this.sessionToken) return
    this.polling = true
    try {
      const current = this.snapshot.revision
      const next = await this.fetchSnapshot(false)
      if (!this.disposed && revisionRank(next.revision, current) > 0) this.publishSnapshot(next)
    } catch (error) {
      if (!this.disposed && error instanceof EditorStoreError && error.code === 'disconnected') {
        this.markDisconnected(error.message)
      }
    } finally {
      this.polling = false
      this.schedulePoll()
    }
  }
}

export default ApiStore
