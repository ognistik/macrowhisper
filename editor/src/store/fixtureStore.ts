import { defaultsSchema } from '../generated/schema'
import {
  cloneFixtureSnapshot,
  createFixtureSnapshot,
  getAllActionNames,
  nextFingerprint,
} from '../fixtures'
import type {
  ActionGroup,
  ConfigSnapshot,
  Edit,
  EditRequest,
  EditorErrorCode,
  FixtureExternalChange,
  FixtureStoreOptions,
  InsertConfig,
  JsonValue,
  MutationResult,
  Revision,
  StoreListener,
  StoreScenario,
} from '../model/types'
import { EditorStoreError } from '../model/types'

const actionGroups: ActionGroup[] = ['inserts', 'urls', 'shortcuts', 'scriptsShell', 'scriptsAS']
const actionGroupSet = new Set<string>(actionGroups)

type PrimitiveKind = 'string' | 'number' | 'integer' | 'boolean'

interface FieldDefinition {
  kind: PrimitiveKind
  nullable: boolean
  minimum?: number
}

const conditionTokensByGroup: Record<ActionGroup, Set<string>> = {
  inserts: new Set([
    'restoreClipboard',
    'restoreClipboardDelay',
    'simEsc',
    'simReturn',
    'nextAction',
    'moveTo',
    'action',
    'actionDelay',
  ]),
  urls: new Set([
    'restoreClipboard',
    'restoreClipboardDelay',
    'simEsc',
    'nextAction',
    'moveTo',
    'action',
    'actionDelay',
  ]),
  shortcuts: new Set([
    'restoreClipboard',
    'restoreClipboardDelay',
    'simEsc',
    'nextAction',
    'moveTo',
    'action',
    'actionDelay',
    'scriptAsync',
    'scriptWaitTimeout',
  ]),
  scriptsShell: new Set([
    'restoreClipboard',
    'restoreClipboardDelay',
    'simEsc',
    'nextAction',
    'moveTo',
    'action',
    'actionDelay',
    'scriptAsync',
    'scriptWaitTimeout',
  ]),
  scriptsAS: new Set([
    'restoreClipboard',
    'restoreClipboardDelay',
    'simEsc',
    'nextAction',
    'moveTo',
    'action',
    'actionDelay',
    'scriptAsync',
    'scriptWaitTimeout',
  ]),
}

const commonActionFields: Record<string, FieldDefinition> = {
  action: { kind: 'string', nullable: false },
  icon: { kind: 'string', nullable: true },
  moveTo: { kind: 'string', nullable: true },
  simEsc: { kind: 'boolean', nullable: true },
  actionDelay: { kind: 'number', nullable: true, minimum: 0 },
  restoreClipboard: { kind: 'boolean', nullable: true },
  restoreClipboardDelay: { kind: 'number', nullable: true, minimum: 0 },
  clipboardStacking: { kind: 'boolean', nullable: true },
  clipboardAttachments: { kind: 'boolean', nullable: true },
  inputCondition: { kind: 'string', nullable: true },
  nextAction: { kind: 'string', nullable: true },
  triggerVoice: { kind: 'string', nullable: true },
  triggerApps: { kind: 'string', nullable: true },
  triggerModes: { kind: 'string', nullable: true },
  triggerUrls: { kind: 'string', nullable: true },
  triggerLogic: { kind: 'string', nullable: true },
}

const actionFieldsByGroup: Record<ActionGroup, Record<string, FieldDefinition>> = {
  inserts: {
    ...commonActionFields,
    simKeypress: { kind: 'boolean', nullable: true },
    smartCasing: { kind: 'boolean', nullable: true },
    smartPunctuation: { kind: 'boolean', nullable: true },
    smartSpacing: { kind: 'boolean', nullable: true },
    simReturn: { kind: 'boolean', nullable: true },
  },
  urls: {
    ...commonActionFields,
    openWith: { kind: 'string', nullable: true },
    openBackground: { kind: 'boolean', nullable: true },
  },
  shortcuts: {
    ...commonActionFields,
    scriptAsync: { kind: 'boolean', nullable: true },
    scriptWaitTimeout: { kind: 'number', nullable: true, minimum: 0 },
  },
  scriptsShell: {
    ...commonActionFields,
    scriptAsync: { kind: 'boolean', nullable: true },
    scriptWaitTimeout: { kind: 'number', nullable: true, minimum: 0 },
  },
  scriptsAS: {
    ...commonActionFields,
    scriptAsync: { kind: 'boolean', nullable: true },
    scriptWaitTimeout: { kind: 'number', nullable: true, minimum: 0 },
  },
}

type SchemaField = {
  type: readonly string[] | string
  minimum?: number
}

const defaultFieldDefinitions: Record<string, FieldDefinition> = Object.fromEntries(
  Object.entries(defaultsSchema as Record<string, SchemaField>).map(([key, schema]) => {
    const types = Array.isArray(schema.type) ? schema.type : [schema.type]
    const kind = types.find((type): type is PrimitiveKind => type !== 'null')
    // The checked-in schema only contains scalar defaults. Keeping this guard
    // here makes a future schema edit fail as a validation error instead of
    // allowing an untyped field through the fixture transaction.
    if (!kind || !['string', 'number', 'integer', 'boolean'].includes(kind)) {
      throw new Error(`Unsupported defaults schema field: ${key}`)
    }
    return [key, { kind, nullable: types.includes('null'), minimum: schema.minimum }]
  }),
)

const defaultFields = new Set(Object.keys(defaultFieldDefinitions))

function cloneValue<T>(value: T): T {
  return structuredClone(value)
}

function hasOwn(value: object, key: PropertyKey): boolean {
  return Object.prototype.hasOwnProperty.call(value, key)
}

function isRecord(value: unknown): value is Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return false
  const prototype = Object.getPrototypeOf(value)
  return prototype === Object.prototype || prototype === null
}

function isJsonValue(value: unknown): value is JsonValue {
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return true
  if (typeof value === 'number') return Number.isFinite(value)
  if (Array.isArray(value)) return value.every((item) => isJsonValue(item))
  if (!isRecord(value)) return false
  return Object.values(value).every((item) => isJsonValue(item))
}

function asJsonValue(value: unknown): JsonValue {
  return value as JsonValue
}

function getPathValue(snapshot: ConfigSnapshot, path: string[]): unknown {
  let current: unknown = snapshot
  for (const segment of path) {
    if (!isRecord(current) || !hasOwn(current, segment)) return undefined
    current = current[segment]
  }
  return current
}

function remoteValueFor(field: string, current: unknown): JsonValue | undefined {
  if (typeof current === 'boolean') return !current
  if (typeof current === 'number') return current + (Number.isInteger(current) ? 1 : 0.1)
  if (typeof current === 'string') {
    if (field === 'triggerLogic') return current.toLowerCase() === 'and' ? 'or' : 'and'
    if (field === 'inputCondition') return current === '' ? 'simEsc' : ''
    if (field === 'nextAction') return current === '' ? 'dailyNotes' : ''
    return `${current} [remote edit]`
  }
  if (current === null || current === undefined) {
    if (field === 'inputCondition') return 'simEsc'
    if (field === 'nextAction') return 'dailyNotes'
    if (field === 'triggerLogic') return 'and'
    if (field === 'icon') return '✦'
    if (field === 'moveTo') return '~/remote-edits'
    return '[remote edit]'
  }
  return undefined
}

/** Set a literal structured path without invoking the special __proto__ setter. */
function setAtPath(snapshot: ConfigSnapshot, path: string[], value: JsonValue): void {
  if (path.length === 0) return
  let current: Record<string, unknown> = snapshot as unknown as Record<string, unknown>
  for (const segment of path.slice(0, -1)) {
    const existing = hasOwn(current, segment) ? current[segment] : undefined
    if (!isRecord(existing)) {
      Object.defineProperty(current, segment, {
        value: {},
        enumerable: true,
        configurable: true,
        writable: true,
      })
    }
    current = current[segment] as Record<string, unknown>
  }
  Object.defineProperty(current, path[path.length - 1], {
    value: cloneValue(value),
    enumerable: true,
    configurable: true,
    writable: true,
  })
}

function removeAtPath(snapshot: ConfigSnapshot, path: string[]): void {
  if (path.length === 0) return
  let current: Record<string, unknown> = snapshot as unknown as Record<string, unknown>
  for (const segment of path.slice(0, -1)) {
    if (!hasOwn(current, segment) || !isRecord(current[segment])) return
    current = current[segment] as Record<string, unknown>
  }
  delete current[path[path.length - 1]]
}

function equalRevision(a: Revision, b: Revision): boolean {
  return a.generation === b.generation && a.version === b.version && a.fingerprint === b.fingerprint
}

function isActionGroup(value: unknown): value is ActionGroup {
  return typeof value === 'string' && actionGroupSet.has(value)
}

function inputConditionError(condition: string, group: ActionGroup): string | undefined {
  if (condition.trim() !== condition || /\s/.test(condition)) return 'Conditions cannot contain spaces.'
  if (condition === '') return undefined
  const tokens = condition.split('|')
  if (tokens.some((token) => token.length === 0)) return 'Choose a setting once. Empty condition tokens are not valid.'
  for (const rawToken of tokens) {
    const token = rawToken.startsWith('!') ? rawToken.slice(1) : rawToken
    if (!token) return 'A negation must name a setting.'
    if (!conditionTokensByGroup[group].has(token)) return `“${rawToken}” is not supported for this action type.`
  }
  return undefined
}

function nonNegativeDelay(value: number | undefined): number {
  if (value === undefined || !Number.isFinite(value)) return 0
  return Math.max(0, value)
}

interface QueueEntry {
  queuedAt: Revision
  externalEpoch: number
  structural: boolean
}

export class FixtureStore {
  private snapshot: ConfigSnapshot
  private scenario: StoreScenario
  private readonly listeners = new Set<StoreListener>()
  private queue: Promise<unknown> = Promise.resolve()
  private readonly writeDelayMs: number
  private persistenceFailure: boolean
  private failureMessage: string
  private externalEpoch = 0
  private generationCounter = 1
  private externalChangeCounter = 0
  private conflictInjected: boolean

  constructor(scenario?: StoreScenario, options?: FixtureStoreOptions)
  constructor(options?: FixtureStoreOptions)
  constructor(scenarioOrOptions: StoreScenario | FixtureStoreOptions = 'populated', suppliedOptions: FixtureStoreOptions = {}) {
    const options = typeof scenarioOrOptions === 'string'
      ? suppliedOptions
      : scenarioOrOptions
    const scenario = typeof scenarioOrOptions === 'string'
      ? scenarioOrOptions
      : options.scenario ?? 'populated'

    this.scenario = scenario
    this.writeDelayMs = nonNegativeDelay(options.writeDelayMs ?? options.latencyMs)
    this.persistenceFailure = options.persistenceFailure ?? options.failWrites ?? false
    this.failureMessage = options.failureMessage ?? 'The fixture could not persist this configuration.'
    this.conflictInjected = scenario !== 'conflict'
    this.snapshot = createFixtureSnapshot(scenario)
  }

  getSnapshot(): ConfigSnapshot {
    return cloneFixtureSnapshot(this.snapshot)
  }

  getScenario(): StoreScenario {
    return this.scenario
  }

  subscribe(listener: StoreListener): () => void {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  setScenario(scenario: StoreScenario): void {
    this.scenario = scenario
    this.conflictInjected = scenario !== 'conflict'
    this.externalEpoch += 1
    const next = createFixtureSnapshot(scenario)
    next.revision = {
      ...next.revision,
      generation: this.nextGeneration(),
    }
    this.snapshot = next
    this.emit()
  }

  /** Make an offline fixture usable again and invalidate drafts from its old generation. */
  reconnect(): ConfigSnapshot {
    if (this.scenario !== 'disconnected') return this.getSnapshot()

    this.scenario = 'populated'
    this.conflictInjected = true
    this.externalEpoch += 1
    const next = cloneFixtureSnapshot(this.snapshot)
    next.runtime = next.disk.status === 'invalid'
      ? { status: 'fallback', message: 'Runtime is using fallback defaults while the file is invalid.' }
      : { status: 'connected', message: 'Connected to the in-memory fixture adapter.' }
    next.revision = {
      generation: this.nextGeneration(),
      version: next.revision.version,
      fingerprint: nextFingerprint(next),
    }
    this.snapshot = next
    this.emit()
    return this.getSnapshot()
  }

  setPersistenceFailure(enabled: boolean, message?: string): void {
    this.persistenceFailure = enabled
    if (message !== undefined) this.failureMessage = message
  }

  /** Alias used by fixture controls and tests that call the option by its short name. */
  setFailWrites(enabled: boolean, message?: string): void {
    this.setPersistenceFailure(enabled, message)
  }

  request(edits: Edit[]): EditRequest {
    return {
      expectedRevision: cloneValue(this.snapshot.revision),
      edits: cloneValue(edits),
    }
  }

  mutate(request: EditRequest): Promise<MutationResult> {
    let queuedRequest: EditRequest
    try {
      queuedRequest = cloneValue(request)
    } catch {
      return Promise.reject(new EditorStoreError('validation', 'A mutation must contain JSON-compatible values.'))
    }

    const entry: QueueEntry = {
      queuedAt: cloneValue(this.snapshot.revision),
      externalEpoch: this.externalEpoch,
      structural: isRecord(queuedRequest) && Array.isArray(queuedRequest.edits)
        ? queuedRequest.edits.some((edit) => isRecord(edit) && Array.isArray(edit.path) && isActionGroup(edit.path[0]) && edit.path.length === 2)
        : false,
    }
    const job = this.queue
      .then(() => this.waitForWriteDelay())
      .then(() => this.perform(queuedRequest, entry))
    // A rejected mutation must not poison subsequent serialized writes.
    this.queue = job.then(() => undefined, () => undefined)
    return job
  }

  createInsert(name: string, action: InsertConfig): Promise<MutationResult> {
    const cleanName = name.trim()
    if (!cleanName) return Promise.reject(new EditorStoreError('validation', 'Give the Insert a name.', ['inserts']))
    if (this.hasActionName(cleanName)) {
      return Promise.reject(new EditorStoreError('validation', 'Action names must be unique across every action group.', ['inserts', cleanName]))
    }
    return this.mutate(this.request([{ path: ['inserts', cleanName], operation: 'set', value: asJsonValue(action) }]))
  }

  duplicateInsert(sourceName: string, targetName: string): Promise<MutationResult> {
    const cleanName = targetName.trim()
    const source = this.getAction('inserts', sourceName)
    if (!source) return Promise.reject(new EditorStoreError('validation', 'The source Insert is unavailable.', ['inserts', sourceName]))
    if (!cleanName) return Promise.reject(new EditorStoreError('validation', 'Give the duplicate a name.', ['inserts']))
    if (this.hasActionName(cleanName)) {
      return Promise.reject(new EditorStoreError('validation', 'Action names must be unique across every action group.', ['inserts', cleanName]))
    }
    return this.mutate(this.request([{ path: ['inserts', cleanName], operation: 'set', value: asJsonValue(source) }]))
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

    const edits: Edit[] = [{ path: ['inserts', cleanName], operation: 'set', value: asJsonValue(source) }]
    for (const group of actionGroups) {
      const groupActions = this.snapshot[group]
      for (const name of Object.keys(groupActions)) {
        const action = groupActions[name]
        if (!isRecord(action) || typeof action.nextAction !== 'string' || action.nextAction.trim() !== sourceName) continue
        // A self-reference is already invalid, but mapping it to the new key
        // keeps the transaction atomic if an intentionally broken fixture is
        // being repaired at the same time.
        const destinationName = group === 'inserts' && name === sourceName ? cleanName : name
        const destinationGroup = group === 'inserts' && name === sourceName ? 'inserts' : group
        edits.push({ path: [destinationGroup, destinationName, 'nextAction'], operation: 'set', value: cleanName })
      }
    }
    if (typeof this.snapshot.defaults.activeAction === 'string' && this.snapshot.defaults.activeAction.trim() === sourceName) {
      edits.push({ path: ['defaults', 'activeAction'], operation: 'set', value: cleanName })
    }
    if (typeof this.snapshot.defaults.nextAction === 'string' && this.snapshot.defaults.nextAction.trim() === sourceName) {
      edits.push({ path: ['defaults', 'nextAction'], operation: 'set', value: cleanName })
    }
    // Remove last so a self-reference can be redirected on the newly-created
    // action before the old structured path disappears.
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

  /**
   * Simulate a disk edit from another process. The change advances the
   * revision and emits once, so queued browser requests can detect it even if
   * no watcher notification has arrived yet. Invalid edits are retained as an
   * invalid disk snapshot to exercise recovery UI.
   */
  simulateExternalChange(change?: FixtureExternalChange): ConfigSnapshot {
    const candidate = cloneFixtureSnapshot(this.snapshot)
    if (change !== undefined) {
      if (typeof change === 'function') {
        change(candidate)
      } else {
        const edits = Array.isArray(change) ? change : [change]
        for (const edit of edits) this.applyExternalEdit(candidate, edit)
      }
    }

    const validity = this.candidateValidationError(candidate)
    if (validity) {
      candidate.disk = { status: 'invalid', message: validity.message }
      if (this.scenario !== 'disconnected') {
        candidate.runtime = { status: 'fallback', message: 'Runtime is using fallback defaults while the file is invalid.' }
      }
    } else if (this.scenario !== 'disconnected') {
      candidate.disk = { status: 'valid' }
      candidate.runtime = { status: 'connected', message: 'Connected to the in-memory fixture adapter.' }
    }

    this.externalChangeCounter += 1
    candidate.revision = {
      generation: this.snapshot.revision.generation,
      version: this.snapshot.revision.version + 1,
      fingerprint: `${nextFingerprint(candidate)}-external-${this.externalChangeCounter}`,
    }
    this.snapshot = candidate
    this.externalEpoch += 1
    this.emit()
    return this.getSnapshot()
  }

  /** Backward-compatible name for callers that model the fixture as a disk watcher. */
  externalChange(change?: FixtureExternalChange): ConfigSnapshot {
    return this.simulateExternalChange(change)
  }

  private async waitForWriteDelay(): Promise<void> {
    if (this.writeDelayMs === 0) return
    await new Promise<void>((resolve) => setTimeout(resolve, this.writeDelayMs))
  }

  private nextGeneration(): string {
    this.generationCounter += 1
    return `fixture-generation-${String(this.generationCounter).padStart(2, '0')}`
  }

  private hasActionName(name: string): boolean {
    return getAllActionNames(this.snapshot).some((item) => item.name === name)
  }

  private getAction(group: ActionGroup, name: string): InsertConfig | undefined {
    const actions = this.snapshot[group]
    if (!hasOwn(actions, name)) return undefined
    return actions[name]
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

  private perform(request: EditRequest, entry: QueueEntry): MutationResult {
    this.validateRequestShape(request)

    if (this.scenario === 'disconnected') {
      throw new EditorStoreError('disconnected', 'The fixture API is disconnected. Keep the draft and retry when it reconnects.', [], request)
    }

    const expected = request.expectedRevision
    const current = this.snapshot.revision
    const canRebaseQueuedField = !entry.structural
      && equalRevision(entry.queuedAt, expected)
      && entry.queuedAt.generation === current.generation
      && entry.externalEpoch === this.externalEpoch
      && entry.queuedAt.version <= current.version
    if (!equalRevision(expected, current) && !canRebaseQueuedField) {
      throw new EditorStoreError('stale', 'This editor is behind the current configuration. Reload before applying the edit.', [], request)
    }

    if (this.scenario === 'conflict' && !this.conflictInjected && request.edits.some((edit) => edit.path[0] === 'inserts')) {
      this.conflictInjected = true
      this.injectConflict(request)
      throw new EditorStoreError('conflict', 'This Insert changed elsewhere. Compare the current revision before reapplying your draft.', ['inserts'], request)
    }

    const candidate = cloneFixtureSnapshot(this.snapshot)
    for (const edit of request.edits) this.applyEdit(candidate, edit, request)
    this.validateCandidate(candidate, request)

    if (this.persistenceFailure) {
      throw new EditorStoreError('persistence', this.failureMessage, [], request)
    }

    candidate.revision = {
      generation: current.generation,
      version: current.version + 1,
      fingerprint: nextFingerprint(candidate),
    }
    this.snapshot = candidate
    this.emit()
    return { snapshot: this.getSnapshot(), request: cloneValue(request) }
  }

  /**
   * The conflict fixture behaves like a remote write once. It changes the
   * requested field when that is safe, advances the disk revision, and then
   * rejects the original request. A caller must fetch the new revision and
   * deliberately reapply its edit; replaying the old request remains stale.
   */
  private injectConflict(request: EditRequest): void {
    const firstInsertEdit = request.edits.find((edit) => edit.path[0] === 'inserts')
    const fallbackName = Object.keys(this.snapshot.inserts)[0]
    const fallbackPath = fallbackName === undefined
      ? undefined
      : ['inserts', fallbackName, 'action']
    const path = firstInsertEdit && firstInsertEdit.path.length >= 3
      && hasOwn(this.snapshot.inserts, firstInsertEdit.path[1])
      ? firstInsertEdit.path
      : fallbackPath

    if (!path) return
    const currentValue = getPathValue(this.snapshot, path)
    let remoteValue = remoteValueFor(path[path.length - 1], currentValue)
    if (path[path.length - 1] === 'nextAction' && remoteValue === path[1]) {
      const alternate = Object.keys(this.snapshot.inserts).find((name) => name !== path[1])
      remoteValue = alternate ?? ''
    }
    if (remoteValue === undefined) return
    this.simulateExternalChange({ path, operation: 'set', value: remoteValue })
  }

  private validateRequestShape(request: EditRequest): void {
    if (!isRecord(request) || !isRecord(request.expectedRevision) || !Array.isArray(request.edits)) {
      throw new EditorStoreError('validation', 'A mutation needs a revision and a list of edits.', [], request)
    }
    const revision = request.expectedRevision as unknown as Record<string, unknown>
    if (
      typeof revision.generation !== 'string'
      || revision.generation.length === 0
      || typeof revision.fingerprint !== 'string'
      || revision.fingerprint.length === 0
      || typeof revision.version !== 'number'
      || !Number.isInteger(revision.version)
      || revision.version < 0
    ) {
      throw new EditorStoreError('validation', 'A mutation needs a valid expected revision.', [], request)
    }
    if (request.edits.length === 0) {
      throw new EditorStoreError('validation', 'A mutation needs at least one edit.', [], request)
    }
    for (const edit of request.edits) {
      if (!isRecord(edit) || !Array.isArray(edit.path) || edit.path.some((segment) => typeof segment !== 'string')) {
        throw new EditorStoreError('validation', 'Each edit needs a structured path.', [], request)
      }
      if (edit.operation !== 'set' && edit.operation !== 'remove') {
        throw new EditorStoreError('validation', 'Each edit needs a set or remove operation.', edit.path, request)
      }
      const hasValue = hasOwn(edit, 'value')
      if (edit.operation === 'set' && (!hasValue || edit.value === undefined || !isJsonValue(edit.value))) {
        throw new EditorStoreError('validation', 'A set edit needs a JSON value.', edit.path, request)
      }
      if (edit.operation === 'remove' && hasValue) {
        throw new EditorStoreError('validation', 'A remove edit must omit its value.', edit.path, request)
      }
    }
  }

  private applyEdit(candidate: ConfigSnapshot, edit: Edit, request: EditRequest): void {
    const path = edit.path
    if (path.length === 0 || path.some((segment) => segment.length === 0)) {
      throw new EditorStoreError('validation', 'An edit needs non-empty structured path segments.', path, request)
    }

    if (path[0] === 'defaults') {
      if (path.length !== 2 || !defaultFields.has(path[1])) {
        throw new EditorStoreError('validation', 'That Defaults field is not editable.', path, request)
      }
      if (edit.operation === 'set') setAtPath(candidate, path, edit.value as JsonValue)
      else removeAtPath(candidate, path)
      return
    }

    if (!isActionGroup(path[0]) || (path.length !== 2 && path.length !== 3)) {
      throw new EditorStoreError('validation', 'That configuration path is not editable.', path, request)
    }

    const group = path[0]
    const name = path[1]
    if (name.trim() === '') {
      throw new EditorStoreError('validation', 'Action names cannot be empty.', path, request)
    }
    const actions = candidate[group]
    if (!isRecord(actions)) {
      throw new EditorStoreError('validation', 'The action group is unavailable.', [group], request)
    }

    if (path.length === 2) {
      if (edit.operation === 'set') {
        if (hasOwn(actions, name)) {
          throw new EditorStoreError('validation', 'An action with this name already exists.', path, request)
        }
        if (!isRecord(edit.value) || typeof edit.value.action !== 'string') {
          throw new EditorStoreError('validation', 'An action needs a text payload.', path, request)
        }
        setAtPath(candidate, path, edit.value as JsonValue)
      } else {
        if (!hasOwn(actions, name)) {
          throw new EditorStoreError('validation', 'The action is no longer available.', path, request)
        }
        removeAtPath(candidate, path)
      }
      return
    }

    const definition = actionFieldsByGroup[group][path[2]]
    if (!definition) {
      throw new EditorStoreError('validation', 'That action field is not editable.', path, request)
    }
    if (!hasOwn(actions, name) || !isRecord(actions[name])) {
      throw new EditorStoreError('validation', 'The referenced action is no longer available.', [group, name], request)
    }
    if (edit.operation === 'set') setAtPath(candidate, path, edit.value as JsonValue)
    else removeAtPath(candidate, path)
  }

  private validateCandidate(candidate: ConfigSnapshot, request: EditRequest): void {
    this.validateCandidateOrThrow(candidate, request)
  }

  private candidateValidationError(candidate: ConfigSnapshot): EditorStoreError | undefined {
    try {
      this.validateCandidateOrThrow(candidate, {
        expectedRevision: candidate.revision,
        edits: [{ path: ['defaults', 'watch'], operation: 'set', value: (isRecord(candidate.defaults) ? candidate.defaults.watch : null) as JsonValue }],
      })
      return undefined
    } catch (error) {
      return error instanceof EditorStoreError ? error : new EditorStoreError('validation', 'The external configuration is invalid.')
    }
  }

  private validateCandidateOrThrow(candidate: ConfigSnapshot, request: EditRequest): void {
    if (!isRecord(candidate.defaults)) {
      throw new EditorStoreError('validation', 'Defaults must be an object.', ['defaults'], request)
    }

    for (const field of Object.keys(candidate.defaults)) {
      const definition = defaultFieldDefinitions[field]
      if (!definition) {
        throw new EditorStoreError('validation', `“${field}” is not a supported Defaults field.`, ['defaults', field], request)
      }
      this.validateFieldValue(candidate.defaults[field], definition, ['defaults', field], request)
      if ((field === 'icon' || field === 'moveTo') && candidate.defaults[field] === '.none') {
        throw new EditorStoreError('validation', `'.none' is not allowed for Defaults ${field}.`, ['defaults', field], request)
      }
    }

    const names = new Set<string>()
    const nextActions = new Map<string, { target: string; path: string[] }>()
    for (const group of actionGroups) {
      const actions = candidate[group]
      if (!isRecord(actions)) {
        throw new EditorStoreError('validation', 'Action groups must be objects.', [group], request)
      }
      for (const name of Object.keys(actions).sort()) {
        if (name.trim() === '') {
          throw new EditorStoreError('validation', 'Action names cannot be empty.', [group, name], request)
        }
        if (names.has(name)) {
          throw new EditorStoreError('validation', `Action names must be unique across every action group (duplicate “${name}”).`, [group, name], request)
        }
        names.add(name)

        const action = actions[name]
        if (!isRecord(action)) {
          throw new EditorStoreError('validation', 'An action definition must be an object.', [group, name], request)
        }
        const definitions = actionFieldsByGroup[group]
        if (!hasOwn(action, 'action') || typeof action.action !== 'string') {
          throw new EditorStoreError('validation', 'Every action needs a text payload.', [group, name, 'action'], request)
        }
        for (const field of Object.keys(action)) {
          const definition = definitions[field]
          if (!definition) {
            throw new EditorStoreError('validation', `“${field}” is not supported for this action type.`, [group, name, field], request)
          }
          this.validateFieldValue(action[field], definition, [group, name, field], request)
          if ((field === 'icon' || field === 'moveTo') && action[field] === '.none') {
            throw new EditorStoreError('validation', `'.none' is not allowed for action ${field}.`, [group, name, field], request)
          }
        }

        const condition = action.inputCondition
        if (typeof condition === 'string') {
          const message = inputConditionError(condition, group)
          if (message) throw new EditorStoreError('validation', message, [group, name, 'inputCondition'], request)
        }

        if (typeof action.triggerLogic === 'string' && !/^(and|or)$/i.test(action.triggerLogic)) {
          throw new EditorStoreError('validation', 'Trigger logic must be Any (OR) or All (AND).', [group, name, 'triggerLogic'], request)
        }

        if (typeof action.nextAction === 'string') {
          const target = action.nextAction.trim()
          if (target !== '') nextActions.set(name, { target, path: [group, name, 'nextAction'] })
        }
      }
    }

    this.validateReference(candidate.defaults.activeAction, names, 'activeAction', 'fallback action', request)
    this.validateReference(candidate.defaults.nextAction, names, 'nextAction', 'default next action', request)
    const activeAction = typeof candidate.defaults.activeAction === 'string' ? candidate.defaults.activeAction.trim() : ''
    const defaultNextAction = typeof candidate.defaults.nextAction === 'string' ? candidate.defaults.nextAction.trim() : ''
    if (activeAction !== '' && activeAction === defaultNextAction) {
      throw new EditorStoreError('validation', 'The fallback action and default next action must be different.', ['defaults', 'nextAction'], request)
    }

    for (const { target, path } of nextActions.values()) {
      if (!names.has(target)) {
        throw new EditorStoreError('validation', `The next action “${target}” is not available.`, path, request)
      }
    }

    const visiting = new Set<string>()
    const visited = new Set<string>()
    const visit = (name: string): void => {
      if (visited.has(name)) return
      if (visiting.has(name)) {
        const cyclePath = nextActions.get(name)?.path ?? ['actions', name, 'nextAction']
        throw new EditorStoreError('validation', `The action chain contains a cycle involving “${name}”.`, cyclePath, request)
      }
      visiting.add(name)
      const next = nextActions.get(name)
      if (next) visit(next.target)
      visiting.delete(name)
      visited.add(name)
    }
    for (const name of nextActions.keys()) visit(name)
  }

  private validateReference(
    value: unknown,
    names: Set<string>,
    field: string,
    label: string,
    request: EditRequest,
  ): void {
    if (value === null || value === undefined) return
    if (typeof value !== 'string') {
      throw new EditorStoreError('validation', `Choose an existing action for the ${label}, or clear it.`, ['defaults', field], request)
    }
    const reference = value.trim()
    if (reference !== '' && !names.has(reference)) {
      throw new EditorStoreError('validation', `Choose an existing action for the ${label}, or clear it.`, ['defaults', field], request)
    }
  }

  private validateFieldValue(value: unknown, definition: FieldDefinition, path: string[], request: EditRequest): void {
    if (value === undefined) return
    if (value === null) {
      if (definition.nullable) return
      throw new EditorStoreError('validation', 'This field cannot be null.', path, request)
    }
    if (definition.kind === 'string' && typeof value !== 'string') {
      throw new EditorStoreError('validation', 'Use text for this field.', path, request)
    }
    if (definition.kind === 'boolean' && typeof value !== 'boolean') {
      throw new EditorStoreError('validation', 'Use true, false, or Default for this field.', path, request)
    }
    if ((definition.kind === 'number' || definition.kind === 'integer') && typeof value !== 'number') {
      throw new EditorStoreError('validation', 'Use a number for this field.', path, request)
    }
    if (typeof value === 'number') {
      if (!Number.isFinite(value)) throw new EditorStoreError('validation', 'Numbers must be finite.', path, request)
      if (definition.kind === 'integer' && !Number.isInteger(value)) {
        throw new EditorStoreError('validation', 'Use a whole number for this field.', path, request)
      }
      if (definition.minimum !== undefined && value < definition.minimum) {
        throw new EditorStoreError('validation', `Use a number of ${definition.minimum} or more.`, path, request)
      }
    }
  }

  private applyExternalEdit(candidate: ConfigSnapshot, edit: Edit): void {
    if (!isRecord(edit) || !Array.isArray(edit.path) || edit.path.some((segment) => typeof segment !== 'string' || segment.length === 0)) {
      throw new EditorStoreError('validation', 'An external change needs a structured path.')
    }
    if (edit.operation === 'set') {
      if (!isJsonValue(edit.value)) throw new EditorStoreError('validation', 'An external set edit needs a JSON value.', edit.path)
      setAtPath(candidate, edit.path, edit.value)
    } else if (edit.operation === 'remove') {
      removeAtPath(candidate, edit.path)
    } else {
      throw new EditorStoreError('validation', 'An external change needs a set or remove operation.', edit.path)
    }
  }

  private emit(): void {
    const snapshot = this.getSnapshot()
    for (const listener of this.listeners) {
      // Listener failures must not turn a committed transaction into a
      // rejected request. Observers receive a copy and can recover on the
      // next notification.
      try {
        listener(snapshot)
      } catch {
        // Intentionally ignored: the store state is already committed.
      }
    }
  }
}

export function isEditorStoreError(error: unknown, code?: EditorErrorCode): error is EditorStoreError {
  return error instanceof EditorStoreError && (code === undefined || error.code === code)
}
