import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { ChangeEvent, FocusEvent, ReactNode } from 'react'
import {
  ArrowLeftIcon,
  CheckIcon,
  ChevronDownIcon,
  CodeIcon,
  CopyIcon,
  Cross2Icon,
  ExclamationTriangleIcon,
  FileTextIcon,
  GearIcon,
  GlobeIcon,
  LightningBoltIcon,
  Link1Icon,
  MagnifyingGlassIcon,
  MinusCircledIcon,
  Pencil1Icon,
  PlusIcon,
  ResetIcon,
  RocketIcon,
  ScissorsIcon,
  TrashIcon,
  UpdateIcon,
} from '@radix-ui/react-icons'
import { getAllActionNames } from './fixtures'
import { defaultsSchema } from './generated/schema'
import { FixtureStore } from './store/fixtureStore'
import type {
  ActionGroup,
  ConfigSnapshot,
  Edit,
  InsertConfig,
  JsonValue,
  Revision,
  Scalar,
  StoreScenario,
  ThemeChoice,
} from './model/types'
import { isEditorStoreError } from './model/types'

type Screen = 'defaults' | ActionGroup
type FieldValue = Scalar | undefined
type DraftStatus = 'dirty' | 'saving' | 'saved' | 'error'

interface DraftEntry {
  path: string[]
  value: FieldValue
  baseValue: FieldValue
  baseRevision: Revision
  status: DraftStatus
  error?: string
  errorCode?: string
  request?: Edit[]
  version: number
  requestId?: number
  reviewed?: boolean
}

interface GroupDefinition {
  id: ActionGroup
  label: string
  shortLabel: string
  icon: ReactNode
  description: string
}

interface SelectOption {
  value: string
  label: string
}

const groups: GroupDefinition[] = [
  { id: 'inserts', label: 'Inserts', shortLabel: 'Insert', icon: <FileTextIcon />, description: 'Paste or type text into the focused app.' },
  { id: 'urls', label: 'URLs', shortLabel: 'URL', icon: <GlobeIcon />, description: 'Open a web address or app.' },
  { id: 'shortcuts', label: 'Shortcuts', shortLabel: 'Shortcut', icon: <LightningBoltIcon />, description: 'Run a macOS Shortcut.' },
  { id: 'scriptsShell', label: 'Shell', shortLabel: 'Shell', icon: <CodeIcon />, description: 'Run a shell command.' },
  { id: 'scriptsAS', label: 'AppleScript', shortLabel: 'AppleScript', icon: <RocketIcon />, description: 'Run AppleScript source.' },
]

export const overrideFields = ['icon', 'moveTo', 'simEsc', 'simKeypress', 'smartCasing', 'smartPunctuation', 'smartSpacing', 'actionDelay', 'simReturn', 'restoreClipboard', 'restoreClipboardDelay', 'clipboardStacking', 'clipboardAttachments']

const groupById = new Map(groups.map((group) => [group.id, group]))

/**
 * These are UI metadata keys, not a second schema. The generated schema owns
 * types/defaults/descriptions; this list only describes which fields receive
 * a structured control in this milestone. The two legacy aliases are kept
 * read-only by the backend and intentionally have no editor control.
 */
const booleanFields = new Set([
  'disableUpdateCheck',
  'muteNotifications',
  'simEsc',
  'simKeypress',
  'smartCasing',
  'smartPunctuation',
  'smartSpacing',
  'simReturn',
  'restoreClipboard',
  'scriptAsync',
  'clipboardStacking',
  'clipboardAttachments',
  'muteTriggers',
  'autoUpdateConfig',
  'redactedLogs',
])

type BooleanFieldLabels = { on: string; off: string }

const booleanFieldLabels: Record<string, BooleanFieldLabels> = {
  disableUpdateCheck: { on: 'Disable checks', off: 'Allow checks' },
  muteNotifications: { on: 'Mute notifications', off: 'Show notifications' },
  simEsc: { on: 'Simulate Escape', off: 'Skip Escape' },
  simKeypress: { on: 'Type characters', off: 'Paste text' },
  smartCasing: { on: 'Adjust casing', off: 'Keep casing' },
  smartPunctuation: { on: 'Adjust punctuation', off: 'Keep punctuation' },
  smartSpacing: { on: 'Adjust spacing', off: 'Keep spacing' },
  simReturn: { on: 'Press Return', off: 'Do not press Return' },
  restoreClipboard: { on: 'Restore clipboard', off: 'Keep new clipboard' },
  scriptAsync: { on: 'Run asynchronously', off: 'Wait for script' },
  clipboardStacking: { on: 'Stack clipboard context', off: 'Use one clipboard value' },
  clipboardAttachments: { on: 'Keep attachments', off: 'Drop attachments' },
  muteTriggers: { on: 'Mute trigger matching', off: 'Evaluate triggers' },
  autoUpdateConfig: { on: 'Update on startup', off: 'Leave config unchanged' },
  redactedLogs: { on: 'Redact sensitive values', off: 'Include values in logs' },
}

const numberUnits: Record<string, string> = {
  actionDelay: 'seconds',
  returnDelay: 'seconds',
  restoreClipboardDelay: 'seconds',
  scheduledActionTimeout: 'seconds',
  scriptWaitTimeout: 'seconds',
  clipboardBuffer: 'seconds',
  history: 'days',
}

export const defaultFieldGroups: Array<{ key: string; label: string; description: string; fields: string[] }> = [
  {
    key: 'general',
    label: 'General behavior',
    description: 'Defaults used when an action leaves a setting at Default.',
    fields: ['activeAction', 'nextAction', 'disableUpdateCheck', 'muteNotifications'],
  },
  {
    key: 'insertion',
    label: 'Insertion',
    description: 'How text is placed into the frontmost application.',
    fields: ['simEsc', 'simKeypress', 'smartCasing', 'smartPunctuation', 'smartSpacing', 'actionDelay', 'simReturn', 'returnDelay'],
  },
  {
    key: 'clipboard',
    label: 'Clipboard',
    description: 'Capture and restore behavior for the full action chain.',
    fields: ['restoreClipboard', 'restoreClipboardDelay', 'clipboardStacking', 'clipboardAttachments', 'clipboardBuffer', 'clipboardIgnore'],
  },
  {
    key: 'recordings',
    label: 'Recordings',
    description: 'Where processed recordings go and how long they remain available.',
    fields: ['watch', 'moveTo', 'history', 'scheduledActionTimeout'],
  },
  {
    key: 'scripts',
    label: 'Scripts and triggers',
    description: 'Global defaults for script execution and trigger matching.',
    fields: ['scriptAsync', 'scriptWaitTimeout', 'bypassModes', 'muteTriggers'],
  },
  {
    key: 'advanced',
    label: 'Advanced',
    description: 'Settings that affect maintenance and diagnostic output.',
    fields: ['icon', 'autoUpdateConfig', 'redactedLogs'],
  },
]

const defaultFieldLabels: Record<string, { label: string; description: string }> = {
  watch: { label: 'Watch folder', description: 'Superwhisper folder containing recordings.' },
  disableUpdateCheck: { label: 'Automatic update checks', description: 'Allow Macrowhisper to check for new versions.' },
  muteNotifications: { label: 'System notifications', description: 'Show completion and error notifications.' },
  activeAction: { label: 'Fallback action', description: 'Action used when no trigger matches.' },
  nextAction: { label: 'Default next action', description: 'Only applies to the first step of a chain.' },
  icon: { label: 'Default icon', description: 'Icon shown alongside actions when they do not override it.' },
  moveTo: { label: 'Move recording', description: 'Where processed recording folders should go.' },
  simEsc: { label: 'Simulate Escape', description: 'Press Escape before executing an action.' },
  simKeypress: { label: 'Type instead of paste', description: 'Use keystrokes when the focused app blocks paste.' },
  smartCasing: { label: 'Smart casing', description: 'Adjust the first letter at a reliable insertion boundary.' },
  smartPunctuation: { label: 'Smart punctuation', description: 'Remove conflicting punctuation at insertion boundaries.' },
  smartSpacing: { label: 'Smart spacing', description: 'Normalize spaces around inserted text.' },
  actionDelay: { label: 'Action delay', description: 'Wait before the action starts.' },
  history: { label: 'History retention', description: 'Days to keep recording history. Empty means keep forever.' },
  simReturn: { label: 'Press Return after insert', description: 'Press Return after an Insert completes.' },
  returnDelay: { label: 'Return delay', description: 'Wait before pressing Return.' },
  restoreClipboard: { label: 'Restore clipboard', description: 'Restore the original clipboard after the action chain.' },
  restoreClipboardDelay: { label: 'Clipboard restore delay', description: 'Wait before restoring the original clipboard.' },
  scheduledActionTimeout: { label: 'Scheduled action timeout', description: 'How long a scheduled action waits for a session.' },
  scriptAsync: { label: 'Run scripts asynchronously', description: 'Continue immediately instead of waiting for a script.' },
  scriptWaitTimeout: { label: 'Script wait timeout', description: 'Maximum wait when a script runs synchronously.' },
  clipboardStacking: { label: 'Stack clipboard context', description: 'Keep eligible clipboard changes in order.' },
  clipboardAttachments: { label: 'Keep clipboard attachments', description: 'Preserve supported files and images during handoff.' },
  clipboardBuffer: { label: 'Clipboard buffer', description: 'Seconds of clipboard history captured before dictation.' },
  clipboardIgnore: { label: 'Ignore clipboard apps', description: 'Regex for apps whose clipboard changes should be skipped.' },
  bypassModes: { label: 'Bypass modes', description: 'Pipe-separated Superwhisper modes to leave untouched.' },
  muteTriggers: { label: 'Mute all triggers', description: 'Skip trigger matching and use the fallback action.' },
  autoUpdateConfig: { label: 'Update config on startup', description: 'Apply schema changes and formatting on startup.' },
  redactedLogs: { label: 'Redact sensitive logs', description: 'Keep dictation, clipboard, and context values out of logs.' },
}

const actionFieldLabels: Record<string, { label: string; description: string }> = {
  icon: { label: 'Icon', description: 'Override the default action icon.' },
  moveTo: { label: 'Move recording', description: 'Override where this action moves its recording folder.' },
  simEsc: { label: 'Simulate Escape', description: 'Override the default Escape behavior for this action.' },
  simKeypress: { label: 'Type instead of paste', description: 'Use keystrokes for this Insert.' },
  smartCasing: { label: 'Smart casing', description: 'Adjust capitalization at insertion boundaries.' },
  smartPunctuation: { label: 'Smart punctuation', description: 'Remove conflicting punctuation at boundaries.' },
  smartSpacing: { label: 'Smart spacing', description: 'Normalize spaces around inserted text.' },
  actionDelay: { label: 'Action delay', description: 'Wait before this action starts.' },
  simReturn: { label: 'Press Return after insert', description: 'Press Return after this Insert completes.' },
  restoreClipboard: { label: 'Restore clipboard', description: 'Override clipboard restoration for this action chain.' },
  restoreClipboardDelay: { label: 'Clipboard restore delay', description: 'Override the delay before clipboard restoration.' },
  clipboardStacking: { label: 'Stack clipboard context', description: 'Override stacking for the chain rooted at this action.' },
  clipboardAttachments: { label: 'Keep clipboard attachments', description: 'Override attachment handoff for this chain.' },
  scriptAsync: { label: 'Run asynchronously', description: 'Continue without waiting for this script-like action.' },
  scriptWaitTimeout: { label: 'Script wait timeout', description: 'Maximum wait when this action is synchronous.' },
  nextAction: { label: 'Next action', description: 'Continue with another action after this step.' },
}

const conditionFieldsByGroup: Record<ActionGroup, string[]> = {
  inserts: ['restoreClipboard', 'restoreClipboardDelay', 'simEsc', 'simReturn', 'nextAction', 'moveTo', 'action', 'actionDelay'],
  urls: ['restoreClipboard', 'restoreClipboardDelay', 'simEsc', 'nextAction', 'moveTo', 'action', 'actionDelay'],
  shortcuts: ['restoreClipboard', 'restoreClipboardDelay', 'simEsc', 'nextAction', 'moveTo', 'action', 'actionDelay', 'scriptAsync', 'scriptWaitTimeout'],
  scriptsShell: ['restoreClipboard', 'restoreClipboardDelay', 'simEsc', 'nextAction', 'moveTo', 'action', 'actionDelay', 'scriptAsync', 'scriptWaitTimeout'],
  scriptsAS: ['restoreClipboard', 'restoreClipboardDelay', 'simEsc', 'nextAction', 'moveTo', 'action', 'actionDelay', 'scriptAsync', 'scriptWaitTimeout'],
}

const placeholders = [
  { key: 'swResult', label: 'Result', hint: 'The processed Superwhisper result.' },
  { key: 'selectedText', label: 'Selected text', hint: 'Text selected when recording started.' },
  { key: 'clipboardContext', label: 'Clipboard context', hint: 'Captured clipboard text and attachments.' },
  { key: 'frontApp', label: 'Front app', hint: 'The app that was frontmost for this action.' },
  { key: 'appContext', label: 'App context', hint: 'Accessible context from the front app.' },
  { key: 'appVocabulary', label: 'App vocabulary', hint: 'Likely terms from the front app.' },
  { key: 'date:short', label: 'Date', hint: 'The current date in a short format.' },
  { key: 'actionResult', label: 'Action result', hint: 'Output from an earlier action in this chain.' },
]

const triggerFields = ['triggerVoice', 'triggerApps', 'triggerModes', 'triggerUrls']
const triggerLabels: Record<string, { label: string; description: string; placeholder: string }> = {
  triggerVoice: { label: 'Voice phrases', description: 'Prefix phrases separated with |. Wrap a value in ==...== for raw regex.', placeholder: 'reply|respond' },
  triggerApps: { label: 'Front apps', description: 'App names or bundle IDs. Use ! for exceptions.', placeholder: 'Mail|com.apple.mail' },
  triggerModes: { label: 'Superwhisper modes', description: 'Mode names separated with |.', placeholder: 'writing|notes' },
  triggerUrls: { label: 'Browser URLs', description: 'Domains or URL prefixes separated with |.', placeholder: 'docs.example.com' },
}

function pathKey(path: string[]): string {
  return path.join('\u001f')
}

function readPath(snapshot: ConfigSnapshot, path: string[]): FieldValue {
  let current: unknown = snapshot
  for (const segment of path) {
    if (typeof current !== 'object' || current === null || !Object.prototype.hasOwnProperty.call(current, segment)) return undefined
    current = (current as Record<string, unknown>)[segment]
  }
  return current as FieldValue
}

function cloneValue<T>(value: T): T {
  return structuredClone(value)
}

function sourceForAction(name: string, action: InsertConfig): 'custom' | 'inherited' | 'template' | 'invalid' {
  if (name === 'brokenLink' || action.nextAction === 'does-not-exist' || action.triggerLogic === 'xor') return 'invalid'
  if (action.action === '.autoPaste' || action.action === '.none') return 'template'
  if (name === 'dailyNotes') return 'inherited'
  return 'custom'
}

function schemaDefault(key: string): Scalar {
  const entry = (defaultsSchema as Record<string, { default?: unknown }>)[key]
  return entry && Object.prototype.hasOwnProperty.call(entry, 'default') ? entry.default as Scalar : null
}

function effectiveDefault(snapshot: ConfigSnapshot, key: string): Scalar {
  const value = (snapshot.defaults as unknown as Record<string, FieldValue>)[key]
  return value === null || value === undefined ? schemaDefault(key) : value
}

function booleanText(field: string, value: boolean): string {
  const labels = booleanFieldLabels[field]
  return labels ? (value ? labels.on : labels.off) : value ? 'On' : 'Off'
}

function booleanDefaultText(field: string): string {
  const value = schemaDefault(field)
  return typeof value === 'boolean' ? booleanText(field, value) : 'Off'
}

function inheritedBooleanDefaultText(snapshot: ConfigSnapshot, field: string): string {
  const value = effectiveDefault(snapshot, field)
  return typeof value === 'boolean' ? booleanText(field, value) : 'Off'
}

function numberDefaultText(field: string): string {
  const value = schemaDefault(field)
  return value === null || value === undefined || value === '' ? 'None' : String(value)
}

function inheritedNumberDefaultText(snapshot: ConfigSnapshot, field: string): string {
  const value = effectiveDefault(snapshot, field)
  return value === null || value === undefined || value === '' ? 'None' : String(value)
}

function fieldErrorId(path: string[]): string {
  return `${pathKey(path)}-error`.replace(/[^a-zA-Z0-9_-]/g, '-')
}

function revisionsEqual(a: Revision, b: Revision): boolean {
  return a.generation === b.generation && a.version === b.version && a.fingerprint === b.fingerprint
}

const NULL_CHOICE = '__macrowhisper_null__'
const EMPTY_CHOICE = '__macrowhisper_empty__'

function displayValue(value: FieldValue): string {
  if (value === undefined || value === null) return ''
  return String(value)
}

function statusText(status: DraftStatus | undefined): string {
  if (status === 'dirty') return 'Unsaved'
  if (status === 'saving') return 'Saving…'
  if (status === 'saved') return 'Saved'
  if (status === 'error') return 'Not saved'
  return ''
}

function isActionGroup(value: Screen): value is ActionGroup {
  return value !== 'defaults'
}

function actionOptions(snapshot: ConfigSnapshot, currentPath?: string[]): SelectOption[] {
  const options: SelectOption[] = [{ value: '', label: 'None' }]
  const names = getAllActionNames(snapshot)
    .filter((item) => !(currentPath && item.group === currentPath[0] && item.name === currentPath[1]))
    .sort((a, b) => a.name.localeCompare(b.name))
  for (const item of names) options.push({ value: item.name, label: `${item.name} · ${groupById.get(item.group)?.shortLabel ?? item.group}` })
  return options
}

function actionLabel(snapshot: ConfigSnapshot, name: string | null | undefined): string {
  if (!name) return 'None'
  const match = getAllActionNames(snapshot).find((item) => item.name === name)
  return match ? `${name} · ${groupById.get(match.group)?.shortLabel ?? match.group}` : `${name} · unavailable`
}

function inboundReferences(snapshot: ConfigSnapshot, name: string): string[] {
  const inbound: string[] = []
  if (snapshot.defaults.activeAction === name) inbound.push('Defaults › Fallback action')
  if (snapshot.defaults.nextAction === name) inbound.push('Defaults › Default next action')
  for (const group of groups) {
    for (const [actionName, action] of Object.entries(snapshot[group.id])) {
      if (action.nextAction === name) inbound.push(`${group.label} › ${actionName} › Next action`)
    }
  }
  return inbound
}

function parseCondition(raw: string | null | undefined): Record<string, 'inside' | 'outside'> {
  const values: Record<string, 'inside' | 'outside'> = {}
  for (const token of (raw ?? '').split('|')) {
    if (!token) continue
    const outside = token.startsWith('!')
    const name = outside ? token.slice(1) : token
    if (!name) continue
    values[name] = outside ? 'outside' : 'inside'
  }
  return values
}

interface ConditionAnalysis {
  values: Record<string, 'inside' | 'outside'>
  repeated: string[]
  malformed: boolean
}

function analyzeCondition(raw: string | null | undefined): ConditionAnalysis {
  const values: Record<string, 'inside' | 'outside'> = {}
  const repeated: string[] = []
  let malformed = false
  const seen = new Set<string>()
  for (const token of (raw ?? '').split('|')) {
    if (!token) {
      if (raw) malformed = true
      continue
    }
    const outside = token.startsWith('!')
    const name = outside ? token.slice(1) : token
    if (!name || /\s/.test(name)) {
      malformed = true
      continue
    }
    if (seen.has(name)) repeated.push(name)
    seen.add(name)
    const mode = outside ? 'outside' : 'inside'
    if (values[name] && values[name] !== mode) malformed = true
    values[name] = mode
  }
  return { values, repeated, malformed }
}

function conditionForValues(values: Record<string, 'inside' | 'outside'>): string {
  return Object.entries(values)
    .filter(([, mode]) => mode !== undefined)
    .map(([name, mode]) => mode === 'outside' ? `!${name}` : name)
    .join('|')
}

function ThemeControl({ theme, onChange }: { theme: ThemeChoice; onChange: (theme: ThemeChoice) => void }) {
  return (
    <div className="theme-control" role="group" aria-label="Appearance">
      {(['system', 'light', 'dark'] as ThemeChoice[]).map((choice) => (
        <button
          type="button"
          key={choice}
          className={theme === choice ? 'theme-option is-selected' : 'theme-option'}
          aria-pressed={theme === choice}
          onClick={() => onChange(choice)}
        >
          {choice[0].toUpperCase() + choice.slice(1)}
        </button>
      ))}
    </div>
  )
}

function FieldState({
  entry,
  onRevert,
  onRetry,
  onResync,
  errorId,
}: {
  entry?: DraftEntry
  onRevert: () => void
  onRetry?: () => void
  onResync?: () => void
  errorId?: string
}) {
  if (!entry) return null
  const canResync = entry.status === 'error' && (entry.errorCode === 'conflict' || entry.errorCode === 'stale')
  return (
    <div className="field-state-wrap">
      <span className={`field-state field-state-${entry.status}`} aria-live="polite">
        {entry.status === 'saved' && <CheckIcon aria-hidden="true" />}
        {entry.status === 'error' && <ExclamationTriangleIcon aria-hidden="true" />}
        {statusText(entry.status)}
      </span>
      {(entry.status === 'dirty' || entry.status === 'error') && (
        <button type="button" className="text-button" onClick={onRevert}>Revert</button>
      )}
      {entry.status === 'error' && onRetry && (
        <button type="button" className="text-button" onClick={onRetry}>Retry</button>
      )}
      {canResync && onResync && (
        <button type="button" className="text-button" onClick={onResync}>Review current value</button>
      )}
      {entry.reviewed && entry.status === 'dirty' && <span className="field-comparison">Current: <code>{JSON.stringify(entry.baseValue) ?? '(not set)'}</code><button type="button" className="text-button" onClick={onRetry}>Reapply draft</button></span>}
      {entry.error && <span id={errorId} className="field-error" role="alert">{entry.error}</span>}
    </div>
  )
}

function SectionHeader({ label, description, count }: { label: string; description: string; count?: number }) {
  return (
    <div className="section-heading">
      <div>
        <h2>{label}</h2>
        <p>{description}</p>
      </div>
      {count !== undefined && <span className="section-count">{count}</span>}
    </div>
  )
}

function EmptyState({ onCreate }: { onCreate: () => void }) {
  return (
    <div className="empty-state">
      <div className="empty-state-mark"><PlusIcon aria-hidden="true" /></div>
      <h2>No Inserts yet</h2>
      <p>Create a reusable text action for the app you’re working in. You can add placeholders after the action exists.</p>
      <button type="button" className="primary-button" onClick={onCreate}><PlusIcon aria-hidden="true" /> Create Insert</button>
    </div>
  )
}

interface NavigationPrompt {
  screen: Screen
  name?: string
  label: string
  scenario?: StoreScenario
}

function App({ store: suppliedStore }: { store?: FixtureStore } = {}) {
  const store = useMemo(() => suppliedStore ?? new FixtureStore('populated', { writeDelayMs: 120 }), [suppliedStore])
  const [snapshot, setSnapshot] = useState<ConfigSnapshot>(() => store.getSnapshot())
  const [screen, setScreen] = useState<Screen>('defaults')
  const [selectedName, setSelectedName] = useState('dailyNotes')
  const [search, setSearch] = useState('')
  const [theme, setTheme] = useState<ThemeChoice>(() => {
    try {
      const stored = localStorage.getItem('macrowhisper-editor-theme')
      return stored === 'light' || stored === 'dark' || stored === 'system' ? stored : 'system'
    } catch {
      return 'system'
    }
  })
  const [scenario, setScenario] = useState<StoreScenario>('populated')
  const [drafts, setDrafts] = useState<Record<string, DraftEntry>>({})
  const [createOpen, setCreateOpen] = useState(false)
  const [duplicateOpen, setDuplicateOpen] = useState(false)
  const [createName, setCreateName] = useState('')
  const [createPayload, setCreatePayload] = useState('{{swResult}}')
  const [lifecycleError, setLifecycleError] = useState('')
  const [lifecycleStatus, setLifecycleStatus] = useState<'idle' | 'saving' | 'saved'>('idle')
  const [deleteOpen, setDeleteOpen] = useState(false)
  const [renameValue, setRenameValue] = useState('')
  const [navPrompt, setNavPrompt] = useState<NavigationPrompt | null>(null)
  const [mobileNavOpen, setMobileNavOpen] = useState(false)
  const [mobileActionView, setMobileActionView] = useState<'list' | 'editor'>('list')
  const [isNarrow, setIsNarrow] = useState(() => typeof window !== 'undefined' && window.matchMedia?.('(max-width: 780px)').matches)
  const [pendingCount, setPendingCount] = useState(0)
  const snapshotRef = useRef(snapshot)
  const draftsRef = useRef(drafts)
  const mutationQueueRef = useRef<Promise<boolean>>(Promise.resolve(true))
  const pendingMutationsRef = useRef(new Map<string, Promise<boolean>>())
  const requestCounterRef = useRef(0)
  const epochRef = useRef(0)
  const lifecyclePromiseRef = useRef<Promise<boolean> | null>(null)
  const mobileMenuRef = useRef<HTMLButtonElement>(null)
  const sidebarRef = useRef<HTMLElement>(null)

  snapshotRef.current = snapshot
  draftsRef.current = drafts

  useEffect(() => {
    const media = window.matchMedia?.('(max-width: 780px)')
    if (!media) return
    const update = () => setIsNarrow(media.matches)
    update()
    media.addEventListener?.('change', update)
    return () => media.removeEventListener?.('change', update)
  }, [])

  useEffect(() => {
    if (!isNarrow) return
    if (mobileNavOpen) {
      const firstControl = sidebarRef.current?.querySelector<HTMLElement>('button, a, input, select, textarea')
      firstControl?.focus()
      const closeOnEscape = (event: KeyboardEvent) => {
        if (event.key === 'Escape') {
          event.preventDefault()
          setMobileNavOpen(false)
          return
        }
        if (event.key !== 'Tab') return
        const controls = Array.from(sidebarRef.current?.querySelectorAll<HTMLElement>('button:not([disabled]), a[href], input:not([disabled]), select:not([disabled]), textarea:not([disabled])') ?? [])
        if (controls.length === 0) return
        const current = document.activeElement
        const index = controls.indexOf(current as HTMLElement)
        if (index === -1 || (event.shiftKey && index === 0) || (!event.shiftKey && index === controls.length - 1)) {
          event.preventDefault()
          controls[event.shiftKey ? controls.length - 1 : 0].focus()
        }
      }
      document.addEventListener('keydown', closeOnEscape)
      return () => document.removeEventListener('keydown', closeOnEscape)
    }
    mobileMenuRef.current?.focus()
  }, [isNarrow, mobileNavOpen])

  useEffect(() => {
    document.documentElement.dataset.theme = theme
    try {
      localStorage.setItem('macrowhisper-editor-theme', theme)
    } catch {
      // Appearance is a convenience; private configuration never uses storage.
    }
  }, [theme])

  useEffect(() => {
    if (screen === 'inserts' && selectedName && !snapshot.inserts[selectedName]) {
      setSelectedName(Object.keys(snapshot.inserts)[0] ?? '')
      setMobileActionView('list')
    }
    if (scenario !== store.getScenario()) setScenario(store.getScenario())
  }, [screen, selectedName, snapshot, scenario, store])

  const currentGroup = isActionGroup(screen) ? groupById.get(screen) : undefined
  const currentAction = isActionGroup(screen) && selectedName ? snapshot[screen][selectedName] : undefined

  const valueFor = useCallback((path: string[]): FieldValue => {
    const entry = draftsRef.current[pathKey(path)]
    // A saved entry is only a transient status indicator. Read its value from
    // the latest snapshot so an external update cannot leave a clean control
    // displaying an old value.
    return entry && entry.status !== 'saved' ? entry.value : readPath(snapshotRef.current, path)
  }, [])

  const updateDrafts = useCallback((updater: (previous: Record<string, DraftEntry>) => Record<string, DraftEntry>) => {
    const next = updater(draftsRef.current)
    draftsRef.current = next
    setDrafts(next)
  }, [])

  const setDraftValue = useCallback((path: string[], value: FieldValue) => {
    const key = pathKey(path)
    updateDrafts((previous) => {
      const existing = previous[key]
      const preserveBaseline = existing && existing.status !== 'saved'
      return {
        ...previous,
        [key]: {
          value,
          path: existing?.path ?? path,
          baseValue: preserveBaseline ? existing.baseValue : readPath(snapshotRef.current, path),
          baseRevision: preserveBaseline ? existing.baseRevision : cloneValue(snapshotRef.current.revision),
          status: 'dirty',
          error: undefined,
          errorCode: undefined,
          request: preserveBaseline ? existing.request : undefined,
          version: (preserveBaseline ? existing.version : 0) + 1,
        },
      }
    })
  }, [updateDrafts])

  const commitField = useCallback(async (path: string[], rawValue: FieldValue): Promise<boolean> => {
    const key = pathKey(path)
    let value = rawValue
    const field = path[path.length - 1]
    const numericField = field === 'actionDelay' || field === 'returnDelay' || field === 'restoreClipboardDelay' || field === 'scheduledActionTimeout' || field === 'scriptWaitTimeout' || field === 'clipboardBuffer' || field === 'history'
    if (numericField) {
      if (typeof rawValue === 'string' && rawValue.trim() !== '') value = Number(rawValue)
      else if (typeof rawValue === 'string' && rawValue.trim() === '' && field === 'history') value = null
    }
    const existingDraft = draftsRef.current[key]
    if ((!existingDraft || existingDraft.status === 'saved') && Object.is(value, readPath(snapshotRef.current, path))) return true
    const edit: Edit = value === undefined ? { path, operation: 'remove' } : { path, operation: 'set', value: cloneValue(value) as JsonValue }
    const requestId = ++requestCounterRef.current
    const epoch = epochRef.current
    updateDrafts((previous) => {
      const existing = previous[key]
      const preserveBaseline = existing && existing.status !== 'saved'
      return {
        ...previous,
        [key]: {
          value: rawValue,
          path: existing?.path ?? path,
          baseValue: preserveBaseline ? existing.baseValue : readPath(snapshotRef.current, path),
          baseRevision: preserveBaseline ? existing.baseRevision : cloneValue(snapshotRef.current.revision),
          status: 'saving',
          error: undefined,
          errorCode: undefined,
          request: [edit],
          version: existing?.version ?? 0,
          requestId,
        },
      }
    })
    const operation = async (): Promise<boolean> => {
      const entryAtStart = draftsRef.current[key]
      const request = store.request([edit])
      const expectedRevision = cloneValue(entryAtStart?.baseRevision ?? request.expectedRevision)
      request.expectedRevision = expectedRevision
      try {
        const result = await store.mutate(request)
        const currentSnapshot = snapshotRef.current
        const resultIsCurrent = epoch === epochRef.current
          && (result.snapshot.revision.generation !== currentSnapshot.revision.generation
            || result.snapshot.revision.version >= currentSnapshot.revision.version)
        if (resultIsCurrent) {
          snapshotRef.current = result.snapshot
          setSnapshot(result.snapshot)
        }
        updateDrafts((previous) => {
          if (epoch !== epochRef.current) return previous
          const next = { ...previous }
          const resultRevision = cloneValue(result.snapshot.revision)
          for (const [draftKey, draft] of Object.entries(previous)) {
            if ((draft.status === 'dirty' || draft.status === 'saving') && revisionsEqual(draft.baseRevision, expectedRevision)) {
              // A successful local write advances the revision for every
              // queued local field. Rebase those pending drafts so rapid
              // edits to separate controls stay serializable, while an
              // external subscription still leaves their old baseline intact.
              if (draftKey !== key || draft.requestId !== requestId) {
                next[draftKey] = { ...draft, baseRevision: cloneValue(resultRevision) }
              }
            } else if (draft.status === 'saved') {
              const savedValue = readPath(result.snapshot, draft.path)
              next[draftKey] = {
                ...draft,
                value: savedValue,
                baseValue: savedValue,
                baseRevision: cloneValue(resultRevision),
                request: undefined,
                requestId: undefined,
              }
            }
          }
          const existing = previous[key]
          if (!existing) return next
          if (existing.requestId !== requestId || !Object.is(existing.value, rawValue)) {
            next[key] = { ...existing, baseRevision: cloneValue(resultRevision) }
            return next
          }
          const savedValue = readPath(result.snapshot, path)
          next[key] = {
            ...existing,
            value: savedValue,
            baseValue: savedValue,
            baseRevision: cloneValue(resultRevision),
            status: 'saved',
            error: undefined,
            errorCode: undefined,
            request: undefined,
            requestId: undefined,
          }
          return next
        })
        return true
      } catch (error) {
        const message = error instanceof Error ? error.message : 'The change could not be saved.'
        updateDrafts((previous) => {
          const existing = previous[key]
          if (!existing || existing.requestId !== requestId) return previous
          return {
            ...previous,
            [key]: {
              ...existing,
              status: 'error',
              error: message,
              errorCode: isEditorStoreError(error) ? error.code : undefined,
              request: existing.request ?? [edit],
              requestId: undefined,
            },
          }
        })
        return false
      }
    }
    const queued = mutationQueueRef.current.then(operation, operation)
    mutationQueueRef.current = queued.then(() => true, () => true)
    pendingMutationsRef.current.set(key, queued)
    setPendingCount((count) => count + 1)
    void queued.finally(() => {
      if (pendingMutationsRef.current.get(key) === queued) pendingMutationsRef.current.delete(key)
      setPendingCount((count) => Math.max(0, count - 1))
    })
    return queued
  }, [store, updateDrafts])

  useEffect(() => store.subscribe((next) => {
    snapshotRef.current = next
    setSnapshot(next)
    updateDrafts((previous) => {
      let changed = false
      const reconciled = { ...previous }
      for (const [key, entry] of Object.entries(previous)) {
        if (entry.status !== 'saved') continue
        const value = readPath(next, entry.path)
        reconciled[key] = {
          ...entry,
          value,
          baseValue: value,
          baseRevision: cloneValue(next.revision),
          request: undefined,
          requestId: undefined,
        }
        changed = true
      }
      return changed ? reconciled : previous
    })
  }), [store, updateDrafts])

  const revertField = useCallback((path: string[]) => {
    updateDrafts((previous) => {
      const next = { ...previous }
      delete next[pathKey(path)]
      return next
    })
  }, [updateDrafts])

  const retryField = useCallback((path: string[]) => {
    const entry = draftsRef.current[pathKey(path)]
    if (entry) void commitField(path, entry.value)
  }, [commitField])

  const resyncField = useCallback((path: string[]) => {
    const next = store.getSnapshot()
    snapshotRef.current = next
    setSnapshot(next)
    const key = pathKey(path)
    updateDrafts((previous) => {
      const entry = previous[key]
      if (!entry) return previous
      return {
        ...previous,
        [key]: {
          ...entry,
          path: entry.path ?? path,
          baseValue: readPath(next, path),
          baseRevision: cloneValue(next.revision),
          status: 'dirty',
          error: undefined,
          errorCode: undefined,
          requestId: undefined,
          reviewed: true,
        },
      }
    })
  }, [store, updateDrafts])

  const textHandlers = (path: string[]) => ({
    value: displayValue(valueFor(path)),
    onChange: (event: ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) => setDraftValue(path, event.target.value),
    onBlur: (event: FocusEvent<HTMLInputElement | HTMLTextAreaElement>) => {
      const entry = draftsRef.current[pathKey(path)]
      if (entry?.status === 'dirty' || event.currentTarget.value !== displayValue(readPath(snapshotRef.current, path))) void commitField(path, event.currentTarget.value)
    },
  })

  const applyScenario = useCallback((next: StoreScenario) => {
    epochRef.current += 1
    setScenario(next)
    store.setScenario(next)
    draftsRef.current = {}
    setDrafts({})
    setLifecycleError('')
    setLifecycleStatus('idle')
    setScreen('defaults')
    setSelectedName(next === 'empty' ? '' : 'dailyNotes')
    setMobileActionView('list')
    setMobileNavOpen(false)
  }, [store])

  const reconnectFixture = () => {
    const adapter = store as FixtureStore & { reconnect?: () => void }
    if (adapter.reconnect) {
      adapter.reconnect()
      return
    }
    // Keep the prototype honest when running against an older fixture adapter.
    // This fallback still changes only the in-memory scenario.
    store.setScenario('populated')
  }

  const navigate = useCallback((target: NavigationPrompt) => {
    if (target.scenario) {
      applyScenario(target.scenario)
      return
    }
    setScreen(target.screen)
    if (target.screen === 'inserts') {
      const firstName = target.name ?? Object.keys(snapshotRef.current.inserts)[0] ?? ''
      setSelectedName(firstName)
      setRenameValue(firstName)
      setMobileActionView(target.name || !isNarrow ? (firstName ? 'editor' : 'list') : 'list')
    }
    setMobileNavOpen(false)
  }, [applyScenario, isNarrow])

  const flushDrafts = useCallback(async (): Promise<boolean> => {
    const pending = Array.from(pendingMutationsRef.current.values())
    if (pending.length > 0) await Promise.all(pending)
    let success = true
    for (const [key, entry] of Object.entries(draftsRef.current)) {
      const path = entry.path ?? key.split('\u001f')
      if (entry.status === 'dirty') {
        if (!await commitField(path, entry.value)) success = false
      } else if (entry.status === 'error') {
        success = false
      }
    }
    const after = Array.from(pendingMutationsRef.current.values())
    if (after.length > 0) {
      const results = await Promise.all(after)
      if (results.some((result) => !result)) success = false
    }
    if (Object.values(draftsRef.current).some((entry) => entry.status === 'dirty' || entry.status === 'error' || entry.status === 'saving')) success = false
    return success
  }, [commitField])

  const requestNavigation = useCallback(async (target: NavigationPrompt) => {
    if (!target.scenario && target.screen === screen && (target.name ?? '') === (screen === 'inserts' ? selectedName : '')) return
    if (screen === 'inserts' && renameValue.trim() !== selectedName) {
      const renamed = await renameInsert()
      if (!renamed) {
        setNavPrompt(target)
        return
      }
    }
    if (lifecyclePromiseRef.current) {
      const lifecycleOk = await lifecyclePromiseRef.current
      if (!lifecycleOk) {
        setNavPrompt(target)
        return
      }
    }
    if (await flushDrafts()) {
      navigate(target)
    } else {
      setNavPrompt(target)
    }
  }, [flushDrafts, navigate, renameValue, screen, selectedName])

  const handleSelectAction = async (group: ActionGroup, name: string) => {
    await requestNavigation({ screen: group, name, label: name })
  }

  const goToDefaults = () => void requestNavigation({ screen: 'defaults', label: 'Defaults' })
  const goToGroup = (group: GroupDefinition) => void requestNavigation({ screen: group.id, label: group.label })

  const discardAndNavigate = () => {
    if (!navPrompt) return
    const target = navPrompt
    draftsRef.current = {}
    setDrafts({})
    setNavPrompt(null)
    if (target.scenario) applyScenario(target.scenario)
    else navigate(target)
  }

  const handleScenario = (next: StoreScenario) => {
    if (next === scenario) return
    void requestNavigation({ screen: 'defaults', label: 'Defaults', scenario: next })
  }

  const openCreate = () => {
    setCreateOpen(true)
    setDuplicateOpen(false)
    setCreateName('')
    setCreatePayload('{{swResult}}')
    setLifecycleError('')
  }

  const createInsert = async (duplicate: boolean) => {
    if (lifecycleStatus === 'saving' || lifecyclePromiseRef.current) return false
    setLifecycleError('')
    if (!createName.trim()) {
      setLifecycleError('Give the Insert a name.')
      return false
    }
    if (!duplicate && createPayload.trim() === '') {
      setLifecycleError('Add a payload before creating the Insert.')
      return false
    }
    setLifecycleStatus('saving')
    const operation = (async () => {
      try {
        const result = duplicate
          ? await store.duplicateInsert(selectedName, createName)
          : await store.createInsert(createName, { action: createPayload, triggerLogic: 'or' })
        snapshotRef.current = result.snapshot
        setSnapshot(result.snapshot)
        const createdName = createName.trim()
        setCreateOpen(false)
        setDuplicateOpen(false)
        setCreateName('')
        setLifecycleStatus('saved')
        setScreen('inserts')
        setSelectedName(createdName)
        setRenameValue(createdName)
        setMobileActionView('editor')
        return true
      } catch (error) {
        setLifecycleStatus('idle')
        setLifecycleError(error instanceof Error ? error.message : 'The Insert could not be created.')
        return false
      }
    })()
    lifecyclePromiseRef.current = operation
    try {
      return await operation
    } finally {
      if (lifecyclePromiseRef.current === operation) lifecyclePromiseRef.current = null
    }
  }

  const renameInsert = async (): Promise<boolean> => {
    if (lifecycleStatus === 'saving' || lifecyclePromiseRef.current) return false
    const clean = renameValue.trim()
    if (!clean || clean === selectedName) {
      if (clean === selectedName) setLifecycleStatus('saved')
      return clean === selectedName
    }
    setLifecycleError('')
    setLifecycleStatus('saving')
    const operation = (async () => {
      try {
        const result = await store.renameInsert(selectedName, clean)
        snapshotRef.current = result.snapshot
        setSnapshot(result.snapshot)
        setSelectedName(clean)
        setRenameValue(clean)
        setLifecycleStatus('saved')
        return true
      } catch (error) {
        setLifecycleStatus('idle')
        setLifecycleError(error instanceof Error ? error.message : 'The Insert could not be renamed.')
        return false
      }
    })()
    lifecyclePromiseRef.current = operation
    try {
      return await operation
    } finally {
      if (lifecyclePromiseRef.current === operation) lifecyclePromiseRef.current = null
    }
  }

  const deleteInsert = async () => {
    if (lifecycleStatus === 'saving' || lifecyclePromiseRef.current) return false
    setLifecycleError('')
    setLifecycleStatus('saving')
    const operation = (async () => {
      try {
        const result = await store.deleteInsert(selectedName)
        snapshotRef.current = result.snapshot
        setSnapshot(result.snapshot)
        const next = Object.keys(result.snapshot.inserts)[0] ?? ''
        setDeleteOpen(false)
        setSelectedName(next)
        setRenameValue(next)
        setLifecycleStatus('saved')
        setMobileActionView(next ? 'editor' : 'list')
        if (!next) setScreen('inserts')
        return true
      } catch (error) {
        setLifecycleStatus('idle')
        setLifecycleError(error instanceof Error ? error.message : 'The Insert could not be deleted.')
        return false
      }
    })()
    lifecyclePromiseRef.current = operation
    try {
      return await operation
    } finally {
      if (lifecyclePromiseRef.current === operation) lifecyclePromiseRef.current = null
    }
  }

  const hasDrafts = Object.values(drafts).some((entry) => entry.status === 'dirty' || entry.status === 'saving' || entry.status === 'error')

  useEffect(() => {
    const beforeUnload = (event: BeforeUnloadEvent) => {
      if (!hasDrafts) return
      event.preventDefault()
      event.returnValue = ''
    }
    window.addEventListener('beforeunload', beforeUnload)
    return () => window.removeEventListener('beforeunload', beforeUnload)
  }, [hasDrafts])

  return (
    <div className="app-shell">
      <aside
        id="configuration-navigation"
        ref={sidebarRef}
        className={mobileNavOpen ? 'sidebar is-mobile-open' : 'sidebar'}
        aria-hidden={isNarrow && !mobileNavOpen}
        role={isNarrow && mobileNavOpen ? 'dialog' : undefined}
        aria-modal={isNarrow && mobileNavOpen ? true : undefined}
        aria-label={isNarrow && mobileNavOpen ? 'Configuration navigation' : undefined}
        inert={isNarrow && !mobileNavOpen ? true : undefined}
      >
        <div className="brand-row">
          <div className="brand-mark" aria-hidden="true">MW</div>
          <div>
            <div className="brand-name">Macrowhisper</div>
            <div className="brand-subtitle">Configuration editor</div>
          </div>
          <button type="button" className="icon-button close-mobile" aria-label="Close navigation" onClick={() => setMobileNavOpen(false)}><Cross2Icon /></button>
        </div>

        <nav className="sidebar-nav" aria-label="Configuration sections">
          <div className="nav-label">Workspace</div>
          <button type="button" className={screen === 'defaults' ? 'nav-item is-active' : 'nav-item'} aria-current={screen === 'defaults' ? 'page' : undefined} onClick={goToDefaults}>
            <GearIcon aria-hidden="true" /><span>Defaults</span>
          </button>
          <div className="nav-label nav-label-spaced">Actions</div>
          {groups.map((group) => {
            const count = Object.keys(snapshot[group.id]).length
            return (
              <button
                type="button"
                key={group.id}
                className={screen === group.id ? 'nav-item is-active' : 'nav-item'}
                aria-current={screen === group.id ? 'page' : undefined}
                onClick={() => goToGroup(group)}
              >
                {group.icon}<span>{group.label}</span><span className="nav-count">{count}</span>
              </button>
            )
          })}
        </nav>

        <div className="sidebar-bottom">
          <div className="connection-card">
            <div className="connection-line"><span className={`status-dot status-${snapshot.runtime.status}`} aria-hidden="true" /><span>{snapshot.runtime.status === 'connected' ? 'Fixture connected' : snapshot.runtime.status === 'fallback' ? 'Runtime fallback' : 'Disconnected'}</span></div>
            <p>{snapshot.runtime.message}</p>
            {snapshot.runtime.status === 'disconnected' && <button type="button" className="quiet-button compact connection-action" onClick={reconnectFixture}>Reconnect fixture</button>}
          </div>
          <div className="path-block"><span>CONFIGURATION</span><code>{snapshot.path}</code></div>
          <ThemeControl theme={theme} onChange={setTheme} />
        </div>
      </aside>

      <main className="main-panel">
        <header className="topbar">
          <button ref={mobileMenuRef} type="button" className="mobile-menu-button" aria-expanded={mobileNavOpen} aria-controls="configuration-navigation" onClick={() => setMobileNavOpen(true)}><GearIcon aria-hidden="true" /> Menu</button>
          <div className="breadcrumb"><span>Macrowhisper</span><span className="breadcrumb-separator">/</span><span>{screen === 'defaults' ? 'Defaults' : currentGroup?.label}</span>{currentAction && <><span className="breadcrumb-separator">/</span><strong>{selectedName}</strong></>}</div>
          <div className="topbar-tools">
            <div className="revision-chip" title={`${snapshot.revision.generation} · version ${snapshot.revision.version}`} aria-live="polite"><span className="revision-dot" />{pendingCount > 0 ? ` Saving${pendingCount > 1 ? ` ${pendingCount}` : ''}…` : ` Revision ${snapshot.revision.version}`}</div>
            <label className="scenario-picker">Fixture
              <select aria-label="Fixture scenario" value={scenario} onChange={(event) => handleScenario(event.target.value as StoreScenario)}>
                <option value="populated">Populated</option><option value="invalid">Invalid field</option><option value="conflict">Conflict</option><option value="empty">Empty Inserts</option><option value="disconnected">Disconnected</option>
              </select>
              <ChevronDownIcon aria-hidden="true" />
            </label>
          </div>
        </header>

        <div className="prototype-notice"><span className="status-dot" aria-hidden="true" /><div><strong>Prototype mode</strong><span>Changes stay in this browser tab and do not write your Macrowhisper configuration file.</span></div></div>
        {snapshot.disk.status !== 'valid' && <DiskBanner snapshot={snapshot} />}
        {snapshot.runtime.status === 'disconnected' && <div className="inline-banner warning"><ExclamationTriangleIcon aria-hidden="true" /><div><strong>Working offline</strong><span>Drafts stay in this tab until the fixture adapter reconnects. Retry after choosing a connected scenario.</span></div></div>}

        {screen === 'defaults' ? (
          <DefaultsScreen snapshot={snapshot} valueFor={valueFor} drafts={drafts} textHandlers={textHandlers} setDraftValue={setDraftValue} commitField={commitField} revertField={revertField} retryField={retryField} resyncField={resyncField} />
        ) : screen === 'inserts' ? (
          <div className={`action-workspace mobile-${mobileActionView}`}>
            {(!isNarrow || mobileActionView === 'list') && <ActionList
              snapshot={snapshot}
              selectedName={selectedName}
              search={search}
              setSearch={setSearch}
              onSelect={(name) => void handleSelectAction('inserts', name)}
              onCreate={openCreate}
              onDuplicate={() => { setDuplicateOpen(true); setCreateOpen(false); setCreateName(`${selectedName} copy`); setLifecycleError('') }}
              createOpen={createOpen}
              duplicateOpen={duplicateOpen}
              createName={createName}
              createPayload={createPayload}
              setCreateName={setCreateName}
              setCreatePayload={setCreatePayload}
              onSubmitCreate={() => void createInsert(duplicateOpen)}
              onCancelCreate={() => { setCreateOpen(false); setDuplicateOpen(false); setLifecycleError('') }}
              lifecycleError={lifecycleError}
              lifecycleStatus={lifecycleStatus}
            />}
            {(!isNarrow || mobileActionView === 'editor') && (currentAction ? (
              <InsertEditor
                key={selectedName}
                snapshot={snapshot}
                selectedName={selectedName}
                action={currentAction}
                drafts={drafts}
                valueFor={valueFor}
                setDraftValue={setDraftValue}
                commitField={commitField}
                revertField={revertField}
                retryField={retryField}
                resyncField={resyncField}
                renameValue={renameValue}
                setRenameValue={setRenameValue}
                onRename={() => void renameInsert()}
                onDuplicate={() => { setDuplicateOpen(true); setCreateOpen(false); setCreateName(`${selectedName} copy`); setLifecycleError('') }}
                onDelete={() => setDeleteOpen(true)}
                onBack={() => setMobileActionView('list')}
                lifecycleError={lifecycleError}
                lifecycleStatus={lifecycleStatus}
              />
            ) : (
              <EmptyState onCreate={openCreate} />
            ))}
          </div>
        ) : (
          <UnsupportedActionGroup group={currentGroup!} snapshot={snapshot} />
        )}
      </main>

      {isNarrow && mobileNavOpen && <button type="button" className="mobile-nav-backdrop" tabIndex={-1} aria-label="Close navigation" onClick={() => setMobileNavOpen(false)} />}

      {deleteOpen && <DeleteDialog name={selectedName} references={inboundReferences(snapshot, selectedName)} onClose={() => setDeleteOpen(false)} onDelete={() => void deleteInsert()} busy={lifecycleStatus === 'saving'} />}
      {navPrompt && <NavigationDialog target={navPrompt.label} onClose={() => setNavPrompt(null)} onDiscard={discardAndNavigate} />}
    </div>
  )
}

function DiskBanner({ snapshot }: { snapshot: ConfigSnapshot }) {
  const title = snapshot.disk.status === 'invalid' ? 'Configuration needs attention' : snapshot.disk.status === 'empty' ? 'Configuration file is empty' : 'Configuration unavailable'
  return <div className="inline-banner error"><ExclamationTriangleIcon aria-hidden="true" /><div><strong>{title}</strong><span>{snapshot.disk.message}</span></div></div>
}

interface DefaultsScreenProps {
  snapshot: ConfigSnapshot
  valueFor: (path: string[]) => FieldValue
  drafts: Record<string, DraftEntry>
  textHandlers: (path: string[]) => { value: string; onChange: (event: ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) => void; onBlur: (event: FocusEvent<HTMLInputElement | HTMLTextAreaElement>) => void }
  setDraftValue: (path: string[], value: FieldValue) => void
  commitField: (path: string[], value: FieldValue) => Promise<boolean>
  revertField: (path: string[]) => void
  retryField: (path: string[]) => void
  resyncField: (path: string[]) => void
}

function DefaultsScreen({ snapshot, valueFor, drafts, textHandlers, setDraftValue, commitField, revertField, retryField, resyncField }: DefaultsScreenProps) {
  return (
    <div className="screen-content defaults-screen">
      <div className="screen-intro">
        <div><p className="eyebrow">Workspace defaults</p><h1>Defaults</h1><p className="screen-description">Set the behavior shared by every action. An action can override any inheritable setting.</p></div>
        <div className="intro-meta"><span className="meta-label">CONFIG VERSION</span><strong>2</strong><span className="meta-label">WATCH FOLDER</span><code>{snapshot.defaults.watch ?? '~/Documents/superwhisper'}</code></div>
      </div>
      <div className="defaults-grid">
        <div className="defaults-column">
          {defaultFieldGroups.slice(0, 3).map((section) => <DefaultSection key={section.key} section={section} snapshot={snapshot} valueFor={valueFor} drafts={drafts} textHandlers={textHandlers} setDraftValue={setDraftValue} commitField={commitField} revertField={revertField} retryField={retryField} resyncField={resyncField} />)}
        </div>
        <div className="defaults-column">
          {defaultFieldGroups.slice(3).map((section) => <DefaultSection key={section.key} section={section} snapshot={snapshot} valueFor={valueFor} drafts={drafts} textHandlers={textHandlers} setDraftValue={setDraftValue} commitField={commitField} revertField={revertField} retryField={retryField} resyncField={resyncField} />)}
        </div>
      </div>
    </div>
  )
}

interface DefaultSectionProps extends DefaultsScreenProps {
  section: { key: string; label: string; description: string; fields: string[] }
}

function DefaultSection({ section, snapshot, valueFor, drafts, textHandlers, setDraftValue, commitField, revertField, retryField, resyncField }: DefaultSectionProps) {
  return (
    <section className="settings-section">
      <SectionHeader label={section.label} description={section.description} />
      <div className="field-list">
        {section.fields.map((field) => <DefaultField key={field} field={field} snapshot={snapshot} valueFor={valueFor} drafts={drafts} textHandlers={textHandlers} setDraftValue={setDraftValue} commitField={commitField} revertField={revertField} retryField={retryField} resyncField={resyncField} />)}
      </div>
    </section>
  )
}

function NullableTextControl({
  kind,
  value,
  onChoice,
  onText,
  onBlur,
  ariaLabel,
  errorId,
  isRoot = false,
}: {
  kind: 'icon' | 'moveTo'
  value: FieldValue
  onChoice: (value: FieldValue) => void
  onText: (value: string) => void
  onBlur: (value: string) => void
  ariaLabel: string
  errorId?: string
  isRoot?: boolean
}) {
  const isMove = kind === 'moveTo'
  const isCustomValue = typeof value === 'string' && value !== '' && (!isMove || value !== '.delete')
  const [customOpen, setCustomOpen] = useState(isCustomValue)
  const mode = customOpen || isCustomValue ? 'custom' : value === null || value === undefined ? 'default' : isMove && value === '.delete' ? 'delete' : 'empty'
  const inputId = `${kind}-custom-value`
  return (
    <div className="nullable-control">
      <select aria-label={`${ariaLabel} mode`} value={mode} onChange={(event) => {
        const next = event.target.value
        if (next === 'default') {
          setCustomOpen(false)
          onChoice(null)
        } else if (next === 'empty') {
          setCustomOpen(false)
          onChoice('')
        } else if (next === 'delete') {
          setCustomOpen(false)
          onChoice('.delete')
        } else {
          setCustomOpen(true)
        }
      }}>
        <option value="default">{isRoot ? `Use built-in (${isMove ? 'Keep recording' : 'No icon'})` : 'Default'}</option>
        {!isMove && <option value="empty">No icon</option>}
        {isMove && <option value="empty">Keep recording</option>}
        {isMove && <option value="delete">Delete recording</option>}
        <option value="custom">Custom</option>
      </select>
      {mode === 'custom' && <input
        id={inputId}
        value={displayValue(value) === '.delete' ? '' : displayValue(value)}
        onChange={(event) => onText(event.target.value)}
        onBlur={(event) => onBlur(event.target.value)}
        aria-label={isMove ? 'Recording folder path' : 'Custom icon'}
        aria-describedby={errorId}
        placeholder={isMove ? '~/Documents/processed-recordings' : 'Optional symbol'}
      />}
    </div>
  )
}

function DefaultField({ field, snapshot, valueFor, drafts, textHandlers, setDraftValue, commitField, revertField, retryField, resyncField }: { field: string } & DefaultsScreenProps) {
  const path = ['defaults', field]
  const entry = drafts[pathKey(path)]
  const meta = defaultFieldLabels[field]
  const value = valueFor(path)
  const saveProps = { onRevert: () => revertField(path), onRetry: () => retryField(path), onResync: () => resyncField(path), errorId: fieldErrorId(path) }
  const onChoice = (next: FieldValue) => void commitField(path, next)

  if (field === 'activeAction' || field === 'nextAction') {
    const options = actionOptions(snapshot)
    const rootReferenceValue = value === null || value === undefined ? NULL_CHOICE : value === '' ? EMPTY_CHOICE : displayValue(value)
    const nullChoiceLabel = field === 'activeAction' ? 'None (null)' : 'Use built-in (no next action)'
    const emptyChoiceLabel = field === 'activeAction' ? 'None (empty)' : 'None (empty)'
    return <SettingRow label={meta.label} description={meta.description} state={<FieldState entry={entry} {...saveProps} />} controlId={field}><select id={field} aria-describedby={entry?.error ? fieldErrorId(path) : undefined} aria-label={meta.label} value={rootReferenceValue} onChange={(event) => {
      const next = event.target.value === NULL_CHOICE ? null : event.target.value === EMPTY_CHOICE ? '' : event.target.value
      onChoice(next)
    }}><option value={NULL_CHOICE}>{nullChoiceLabel}</option><option value={EMPTY_CHOICE}>{emptyChoiceLabel}</option>{options.slice(1).map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}</select>{field === 'activeAction' && <span className="field-note">{actionLabel(snapshot, value as string | null)}</span>}</SettingRow>
  }

  if (field === 'icon' || field === 'moveTo') {
    return <SettingRow label={meta.label} description={meta.description} state={<FieldState entry={entry} {...saveProps} />}><NullableTextControl kind={field} value={value} onChoice={onChoice} onText={(next) => setDraftValue(path, next)} onBlur={(next) => { if (entry?.status === 'dirty' || next !== displayValue(readPath(snapshot, path))) void commitField(path, next) }} ariaLabel={meta.label} errorId={fieldErrorId(path)} isRoot /></SettingRow>
  }

  if (field === 'watch' || field === 'clipboardIgnore' || field === 'bypassModes') {
    const props = textHandlers(path)
    return <SettingRow label={meta.label} description={meta.description} state={<FieldState entry={entry} {...saveProps} />} controlId={field}><div className="setting-input-stack"><div className="input-with-affordance"><input id={field} {...props} aria-label={meta.label} aria-describedby={entry?.error ? fieldErrorId(path) : undefined} placeholder={field === 'watch' ? '~/superwhisper' : ''} />{field === 'watch' && <span className="input-affordance"><Link1Icon aria-hidden="true" /></span>}</div><button type="button" className="text-button reset-field-button" onClick={() => onChoice(null)} disabled={value === null || value === undefined}>{field === 'watch' ? 'Use built-in watch folder' : 'Use built-in (none)'}</button></div></SettingRow>
  }

  if (field === 'history' || field === 'actionDelay' || field === 'returnDelay' || field === 'restoreClipboardDelay' || field === 'scheduledActionTimeout' || field === 'scriptWaitTimeout' || field === 'clipboardBuffer') {
    const props = textHandlers(path)
    return <SettingRow label={meta.label} description={meta.description} state={<FieldState entry={entry} {...saveProps} />} controlId={field}><div className="setting-input-stack"><div className="input-with-unit"><input id={field} {...props} aria-label={meta.label} aria-describedby={entry?.error ? fieldErrorId(path) : undefined} inputMode="decimal" type="text" placeholder={field === 'history' ? 'Keep forever' : numberDefaultText(field)} />{field !== 'history' && <span>{numberUnits[field]}</span>}</div><button type="button" className="text-button reset-field-button" onClick={() => onChoice(null)} disabled={value === null || value === undefined}>{field === 'history' ? 'Keep forever' : `Use built-in (${numberDefaultText(field)})`}</button></div></SettingRow>
  }

  if (booleanFields.has(field)) {
    return <SettingRow label={meta.label} description={meta.description} state={<FieldState entry={entry} {...saveProps} />} controlId={field}><select id={field} aria-describedby={entry?.error ? fieldErrorId(path) : undefined} aria-label={meta.label} value={booleanValue(value)} onChange={(event) => onChoice(event.target.value === 'default' ? null : event.target.value === 'on')}><option value="default">Use built-in ({booleanDefaultText(field)})</option><option value="on">{booleanText(field, true)}</option><option value="off">{booleanText(field, false)}</option></select></SettingRow>
  }

  return null
}

function SettingRow({ label, description, state, children, controlId }: { label: string; description: string; state?: ReactNode; children: ReactNode; controlId?: string }) {
  return <div className="setting-row"><div className="setting-copy"><div className="setting-label"><label htmlFor={controlId}>{label}</label>{state}</div><p>{description}</p></div><div className="setting-control">{children}</div></div>
}

interface ActionListProps {
  snapshot: ConfigSnapshot
  selectedName: string
  search: string
  setSearch: (value: string) => void
  onSelect: (name: string) => void
  onCreate: () => void
  onDuplicate: () => void
  createOpen: boolean
  duplicateOpen: boolean
  createName: string
  createPayload: string
  setCreateName: (value: string) => void
  setCreatePayload: (value: string) => void
  onSubmitCreate: () => void
  onCancelCreate: () => void
  lifecycleError: string
  lifecycleStatus: 'idle' | 'saving' | 'saved'
}

function ActionList({ snapshot, selectedName, search, setSearch, onSelect, onCreate, onDuplicate, createOpen, duplicateOpen, createName, createPayload, setCreateName, setCreatePayload, onSubmitCreate, onCancelCreate, lifecycleError, lifecycleStatus }: ActionListProps) {
  const names = Object.keys(snapshot.inserts).filter((name) => name.toLocaleLowerCase().includes(search.toLocaleLowerCase()))
  return (
    <aside className="action-list" aria-label="Insert actions">
      <div className="action-list-heading"><div><p className="eyebrow">Actions</p><h1>Inserts</h1></div><span className="section-count">{Object.keys(snapshot.inserts).length}</span></div>
      <p className="list-description">Text actions for pasting or typing into the focused app.</p>
      <div className="action-list-tools"><label className="search-field"><MagnifyingGlassIcon aria-hidden="true" /><span className="sr-only">Search Inserts</span><input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Search actions" /></label><div className="list-action-buttons"><button type="button" className="primary-button compact" onClick={onCreate}><PlusIcon aria-hidden="true" /> New Insert</button>{selectedName && <button type="button" className="quiet-button compact" onClick={onDuplicate}>Duplicate</button>}</div></div>
      {(createOpen || duplicateOpen) && <div className="create-panel"><div className="panel-kicker">{duplicateOpen ? 'Duplicate Insert' : 'New Insert'}</div><label>Name<input autoFocus value={createName} onChange={(event) => setCreateName(event.target.value)} onKeyDown={(event) => { if (event.key === 'Enter') onSubmitCreate() }} placeholder="e.g. meetingNotes" /></label>{!duplicateOpen && <label>Payload<textarea value={createPayload} onChange={(event) => setCreatePayload(event.target.value)} rows={3} /></label>}<div className="panel-actions"><button type="button" className="quiet-button" onClick={onCancelCreate}>Cancel</button><button type="button" className="primary-button compact" onClick={onSubmitCreate} disabled={lifecycleStatus === 'saving'}>{lifecycleStatus === 'saving' ? 'Creating…' : duplicateOpen ? 'Duplicate' : 'Create Insert'}</button></div>{lifecycleError && <div className="panel-error"><ExclamationTriangleIcon aria-hidden="true" />{lifecycleError}</div>}</div>}
      <div className="action-items" role="listbox" aria-label="Available Inserts">
        {names.map((name) => {
          const action = snapshot.inserts[name]
          const source = sourceForAction(name, action)
          return <button type="button" role="option" aria-selected={name === selectedName} className={name === selectedName ? 'action-item is-selected' : 'action-item'} key={name} onClick={() => onSelect(name)}><span className="action-item-icon">{action.icon || '·'}</span><span className="action-item-copy"><strong>{name}</strong><small>{action.action === '.autoPaste' ? 'Auto-paste template' : action.action === '.none' ? 'Do nothing template' : action.action.replace(/\s+/g, ' ').slice(0, 42) || 'Empty payload'}</small></span><span className={`source-badge source-${source}`}>{source === 'custom' ? 'Custom' : source === 'inherited' ? 'Default' : source === 'template' ? 'Built-in' : 'Invalid'}</span></button>
        })}
        {names.length === 0 && <div className="list-empty"><MagnifyingGlassIcon aria-hidden="true" /><span>{search ? 'No matching Inserts' : 'No Inserts yet'}</span>{!search && <button type="button" className="text-button" onClick={onCreate}>Create one</button>}</div>}
      </div>
      <div className="list-footer"><span><span className="legend-dot legend-custom" /> Custom</span><span><span className="legend-dot legend-inherited" /> Inherits defaults</span></div>
    </aside>
  )
}

interface InsertEditorProps {
  snapshot: ConfigSnapshot
  selectedName: string
  action: InsertConfig
  drafts: Record<string, DraftEntry>
  valueFor: (path: string[]) => FieldValue
  setDraftValue: (path: string[], value: FieldValue) => void
  commitField: (path: string[], value: FieldValue) => Promise<boolean>
  revertField: (path: string[]) => void
  retryField: (path: string[]) => void
  resyncField: (path: string[]) => void
  renameValue: string
  setRenameValue: (value: string) => void
  onRename: () => void
  onDuplicate: () => void
  onDelete: () => void
  onBack: () => void
  lifecycleError: string
  lifecycleStatus: 'idle' | 'saving' | 'saved'
}

function InsertEditor({ snapshot, selectedName, action, drafts, valueFor, setDraftValue, commitField, revertField, retryField, resyncField, renameValue, setRenameValue, onRename, onDuplicate, onDelete, onBack, lifecycleError, lifecycleStatus }: InsertEditorProps) {
  const actionPath = (field: string) => ['inserts', selectedName, field]
  const payloadPath = actionPath('action')
  const payloadEntry = drafts[pathKey(payloadPath)]
  const payload = displayValue(valueFor(payloadPath))
  const payloadMode = payload === '.autoPaste' ? 'autoPaste' : payload === '.none' ? 'none' : 'text'
  const source = sourceForAction(selectedName, { ...action, action: payload })
  const [placeholderOpen, setPlaceholderOpen] = useState(false)
  const [advancedOpen, setAdvancedOpen] = useState(source === 'invalid')
  const [conditionAdvanced, setConditionAdvanced] = useState(false)
  const composingRef = useRef(false)
  const deferredBlurRef = useRef(false)
  const textareaRef = useRef<HTMLTextAreaElement>(null)
  const selectionRef = useRef({ start: payload.length, end: payload.length })
  const boundaryRef = useRef<HTMLDivElement>(null)
  const conditionPath = actionPath('inputCondition')
  const conditionRaw = displayValue(valueFor(conditionPath))
  const conditionValues = parseCondition(conditionRaw)
  const conditionAnalysis = analyzeCondition(conditionRaw)
  const triggerLogicPath = actionPath('triggerLogic')
  const triggerLogic = valueFor(triggerLogicPath)
  const triggerLogicChoice = triggerLogic === null || triggerLogic === undefined ? NULL_CHOICE : triggerLogic === '' ? EMPTY_CHOICE : displayValue(triggerLogic)

  const rememberSelection = () => {
    const element = textareaRef.current
    if (element) selectionRef.current = { start: element.selectionStart, end: element.selectionEnd }
  }

  useEffect(() => {
    if (!placeholderOpen) return
    const closeOnOutsidePointer = (event: PointerEvent) => {
      if (!boundaryRef.current?.contains(event.target as Node)) setPlaceholderOpen(false)
    }
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault()
        setPlaceholderOpen(false)
        textareaRef.current?.focus()
      }
    }
    document.addEventListener('pointerdown', closeOnOutsidePointer)
    document.addEventListener('keydown', closeOnEscape)
    return () => {
      document.removeEventListener('pointerdown', closeOnOutsidePointer)
      document.removeEventListener('keydown', closeOnEscape)
    }
  }, [placeholderOpen])

  const insertPlaceholder = (key: string) => {
    const element = textareaRef.current
    const { start, end } = selectionRef.current
    const insertion = `{{${key}}}`
    const currentPayload = displayValue(valueFor(payloadPath))
    const safeStart = Math.min(start, currentPayload.length)
    const safeEnd = Math.min(Math.max(end, safeStart), currentPayload.length)
    const next = `${currentPayload.slice(0, safeStart)}${insertion}${currentPayload.slice(safeEnd)}`
    if (!element || composingRef.current) return
    element.focus()
    element.setSelectionRange(safeStart, safeEnd)
    // insertText is the browser editing operation that retains native undo.
    // React receives its input event; the explicit draft also supports engines
    // which perform the operation without dispatching that event.
    const inserted = typeof document.execCommand === 'function' && document.execCommand('insertText', false, insertion)
    setDraftValue(payloadPath, inserted ? element.value : next)
    setPlaceholderOpen(false)
    requestAnimationFrame(() => {
      if (!element) return
      element.focus()
      const caret = safeStart + insertion.length
      element.setSelectionRange(caret, caret)
      selectionRef.current = { start: caret, end: caret }
    })
  }

  const commitIfChanged = (path: string[], next: FieldValue) => {
    const entry = drafts[pathKey(path)]
    if (entry?.status === 'dirty' || displayValue(next) !== displayValue(readPath(snapshot, path))) void commitField(path, next)
  }

  const onPayloadBlur = (event: FocusEvent<HTMLDivElement>) => {
    const nextTarget = event.relatedTarget as Node | null
    if (nextTarget && boundaryRef.current?.contains(nextTarget)) return
    if (composingRef.current) { deferredBlurRef.current = true; return }
    setPlaceholderOpen(false)
    const entry = drafts[pathKey(payloadPath)]
    if (entry?.status === 'dirty') commitIfChanged(payloadPath, valueFor(payloadPath))
  }

  const onPlaceholderKey = (event: React.KeyboardEvent<HTMLDivElement>) => {
    const items = Array.from(event.currentTarget.querySelectorAll<HTMLButtonElement>('[role="menuitem"]'))
    const index = items.indexOf(document.activeElement as HTMLButtonElement)
    if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) {
      event.preventDefault()
      const next = event.key === 'Home' ? 0 : event.key === 'End' ? items.length - 1 : (index + (event.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length
      items[next]?.focus()
    }
  }

  useEffect(() => {
    if (placeholderOpen) boundaryRef.current?.querySelector<HTMLButtonElement>('[role="menuitem"]')?.focus()
  }, [placeholderOpen])

  const setActionChoice = (next: 'autoPaste' | 'none' | 'text') => {
    if (next === 'autoPaste') void commitField(payloadPath, '.autoPaste')
    else if (next === 'none') void commitField(payloadPath, '.none')
    else if (payloadMode !== 'text') void commitField(payloadPath, '{{swResult}}')
  }

  const setConditionMode = (field: string, mode: 'always' | 'inside' | 'outside') => {
    const next = { ...conditionValues }
    if (mode === 'always') delete next[field]
    else next[field] = mode
    void commitField(conditionPath, conditionForValues(next))
  }

  const actionMeta = actionFieldLabels

  return (
    <section className="insert-editor">
      <div className="editor-header">
        <button type="button" className="back-button" onClick={onBack}><ArrowLeftIcon aria-hidden="true" /> Inserts</button>
        <div className="editor-header-actions"><SourcePill source={source} /><button type="button" className="quiet-button" onClick={onDuplicate}><CopyIcon aria-hidden="true" /> Duplicate</button><button type="button" className="quiet-button danger-button" onClick={onDelete}><TrashIcon aria-hidden="true" /> Delete</button></div>
      </div>
      <div className="editor-scroll">
        <div className="editor-title-row"><div><p className="eyebrow">Insert action</p><h1>{selectedName}</h1><p className="screen-description">{groupById.get('inserts')?.description}</p></div><div className="editor-revision"><span>Revision</span><strong>{snapshot.revision.version}</strong></div></div>

        {source === 'invalid' && <div className="field-alert"><ExclamationTriangleIcon aria-hidden="true" /><div><strong>This action has invalid configuration.</strong><span>Fix the highlighted fields before saving another change. Existing text is preserved so you can repair it deliberately.</span></div></div>}
        {source === 'template' && <div className="template-callout"><div className="template-icon"><RocketIcon aria-hidden="true" /></div><div><strong>{payloadMode === 'autoPaste' ? 'Auto-paste template' : 'Do nothing template'}</strong><span>{payloadMode === 'autoPaste' ? 'Macrowhisper’s built-in paste behavior supplies the payload and insertion details at runtime.' : 'This action intentionally performs no payload operation. Its triggers and chain settings can still apply.'}</span></div></div>}

        <div className="editor-section identity-section"><div className="section-heading"><div><h2>Identity</h2><p>Names are unique across Inserts, URLs, Shortcuts, Shell, and AppleScript.</p></div></div><div className="rename-row"><label htmlFor="insert-name">Action name</label><div className="rename-control"><input id="insert-name" value={renameValue} onChange={(event) => setRenameValue(event.target.value)} onKeyDown={(event) => { if (event.key === 'Enter') onRename() }} onBlur={() => { if (renameValue.trim() !== selectedName) onRename() }} /><button type="button" className="quiet-button" onClick={onRename} disabled={lifecycleStatus === 'saving' || renameValue.trim() === selectedName}><Pencil1Icon aria-hidden="true" /> Rename</button><FieldLifecycle status={lifecycleStatus} /></div></div>{lifecycleError && <div className="inline-field-error"><ExclamationTriangleIcon aria-hidden="true" />{lifecycleError}</div>}</div>

        <div className="editor-section payload-section"><div className="section-heading"><div><h2>Payload</h2><p>Write text or choose a built-in mode. Placeholders are inserted at the caret and never expanded in the editor.</p></div></div><div className="payload-boundary" ref={boundaryRef} onBlur={onPayloadBlur}><div className="payload-toolbar"><div className="mode-label">{payloadMode === 'text' ? 'Text payload' : 'Built-in mode'}</div><div className="placeholder-menu"><button type="button" className="toolbar-button" aria-haspopup="menu" aria-expanded={placeholderOpen} disabled={payloadMode !== 'text'} title={payloadMode === 'text' ? undefined : 'Choose Custom text to insert a placeholder'} onMouseDown={(event) => event.preventDefault()} onClick={() => { rememberSelection(); setPlaceholderOpen((open) => !open) }}><PlusIcon aria-hidden="true" /> Insert placeholder <ChevronDownIcon aria-hidden="true" /></button>{placeholderOpen && <div className="placeholder-popover" role="menu" aria-label="Insert placeholder" onKeyDown={onPlaceholderKey}>{placeholders.map((item) => <button type="button" role="menuitem" key={item.key} onMouseDown={(event) => event.preventDefault()} onClick={() => insertPlaceholder(item.key)}><span className="placeholder-chip">{'{{'}{item.key}{'}}'}</span><span><strong>{item.label}</strong><small>{item.hint}</small></span></button>)}</div>}</div></div><div className="built-in-choice-row"><ChoiceCard selected={payloadMode === 'autoPaste'} value=".autoPaste" label="Auto-paste" description="Use the built-in paste flow." onClick={() => setActionChoice('autoPaste')} /><ChoiceCard selected={payloadMode === 'none'} value=".none" label="Do nothing" description="Keep triggers and chain settings." onClick={() => setActionChoice('none')} /><ChoiceCard selected={payloadMode === 'text'} value="text" label="Custom text" description="Edit the payload below." onClick={() => setActionChoice('text')} /></div>{payloadMode === 'text' && <><textarea ref={textareaRef} value={payload} aria-label="Insert payload" aria-describedby={payloadEntry?.error ? fieldErrorId(payloadPath) : undefined} rows={8} onChange={(event) => setDraftValue(payloadPath, event.target.value)} onSelect={rememberSelection} onKeyUp={rememberSelection} onFocus={rememberSelection} onCompositionStart={() => { composingRef.current = true }} onCompositionEnd={(event) => {
          composingRef.current = false
          if (deferredBlurRef.current) {
            deferredBlurRef.current = false
            void commitField(payloadPath, event.currentTarget.value)
          }
        }} placeholder="Type the text to insert…" /><div className="payload-footer"><span>{payload.length} characters</span><FieldState entry={payloadEntry} onRevert={() => revertField(payloadPath)} onRetry={() => retryField(payloadPath)} onResync={() => resyncField(payloadPath)} errorId={fieldErrorId(payloadPath)} /></div></>}</div></div>

        <div className="editor-section"><Disclosure title="Insertion behavior" subtitle="Overrides inherited Defaults for this Insert." open={source === 'custom'} onToggle={setAdvancedOpen}><div className="override-grid">{overrideFields.filter((field) => field in actionMeta).map((field) => <fieldset key={field} className="template-field" disabled={payloadMode !== 'text' && (field === 'simEsc' || field === 'restoreClipboard')}><OverrideField field={field} path={actionPath(field)} snapshot={snapshot} value={valueFor(actionPath(field))} entry={drafts[pathKey(actionPath(field))]} meta={actionMeta[field]} onChoice={(value) => void commitField(actionPath(field), value)} onText={(value) => setDraftValue(actionPath(field), value)} onBlur={(value) => commitIfChanged(actionPath(field), value)} onRevert={() => revertField(actionPath(field))} onRetry={() => retryField(actionPath(field))} onResync={() => resyncField(actionPath(field))} />{payloadMode !== 'text' && (field === 'simEsc' || field === 'restoreClipboard') && <p className="template-note">{payloadMode === 'autoPaste' ? 'Template: Off outside text fields; Defaults inside text fields.' : 'Template: Off.'} Stored override is retained.</p>}</fieldset>)}</div><div className="template-note"><MinusCircledIcon aria-hidden="true" /> Null means Default. An empty string is an explicit empty value for fields such as Icon and Move recording.</div></Disclosure></div>

        <div className="editor-section"><Disclosure title="Conditions" subtitle="Apply supported settings inside or outside text fields." open={conditionAdvanced || source === 'invalid'} onToggle={setConditionAdvanced}><div className="condition-intro">An unmet condition falls back to matching Defaults. Payload behavior has its own rule, so the setting name is shown explicitly.</div>{(conditionAnalysis.malformed || conditionAnalysis.repeated.length > 0) && <div className="inline-field-error"><ExclamationTriangleIcon aria-hidden="true" />This saved expression contains {conditionAnalysis.malformed ? 'an invalid token' : 'repeated tokens'}{conditionAnalysis.repeated.length > 0 ? ` (${conditionAnalysis.repeated.join(', ')})` : ''}. It stays intact in Advanced mode until you edit it.</div>}<fieldset className="template-field" disabled={payloadMode !== 'text'}>{payloadMode !== 'text' && <p className="template-note">The built-in mode supplies its own conditions. Your stored expression is retained for Custom text.</p>}<div className="condition-list">{conditionFieldsByGroup.inserts.map((field) => <div className="condition-row" key={field}><div><strong>{field === 'action' ? 'Payload' : actionMeta[field]?.label ?? field}</strong><span>{field === 'action' ? 'Text or built-in action value' : 'Override only in the selected context'}</span></div><select aria-label={`Condition for ${field}`} value={conditionValues[field] ?? 'always'} onChange={(event) => setConditionMode(field, event.target.value as 'always' | 'inside' | 'outside')}><option value="always">Always</option><option value="inside">Inside a text field</option><option value="outside">Outside a text field</option></select></div>)}</div><label className="advanced-toggle"><input type="checkbox" checked={conditionAdvanced} onChange={(event) => setConditionAdvanced(event.target.checked)} /> Keep the raw expression visible</label>{conditionAdvanced && <div className="raw-expression"><input aria-label="Advanced input condition" value={conditionRaw} aria-describedby={drafts[pathKey(conditionPath)]?.error ? fieldErrorId(conditionPath) : undefined} onChange={(event) => setDraftValue(conditionPath, event.target.value)} onBlur={(event) => commitIfChanged(conditionPath, event.target.value)} /><span>Pipe-separated tokens such as <code>action|!simReturn</code>. Existing expressions remain unchanged until edited.</span><FieldState entry={drafts[pathKey(conditionPath)]} onRevert={() => revertField(conditionPath)} onRetry={() => retryField(conditionPath)} onResync={() => resyncField(conditionPath)} errorId={fieldErrorId(conditionPath)} /></div>}</fieldset></Disclosure></div>

        <div className="editor-section"><Disclosure title="Triggers" subtitle="Choose how this action is found from a spoken phrase, app, mode, or URL." open={true} onToggle={() => undefined}><div className="trigger-grid">{triggerFields.map((field) => { const path = actionPath(field); const props = { ...textInputProps(valueFor(path), (value) => setDraftValue(path, value), (value) => commitIfChanged(path, value)) }; return <div className="trigger-field" key={field}><label htmlFor={field}>{triggerLabels[field].label}</label><p>{triggerLabels[field].description}</p><input id={field} {...props} aria-describedby={drafts[pathKey(path)]?.error ? fieldErrorId(path) : undefined} placeholder={triggerLabels[field].placeholder} />{drafts[pathKey(path)] && <FieldState entry={drafts[pathKey(path)]} onRevert={() => revertField(path)} onRetry={() => retryField(path)} onResync={() => resyncField(path)} errorId={fieldErrorId(path)} />}</div>})}</div><div className="logic-row"><div><strong>Trigger logic</strong><span>How configured trigger types combine when more than one is present.</span></div><select aria-label="Trigger logic" value={triggerLogicChoice} onChange={(event) => { const next = event.target.value === NULL_CHOICE ? null : event.target.value === EMPTY_CHOICE ? '' : event.target.value; void commitField(triggerLogicPath, next) }}><option value={NULL_CHOICE}>Default (Any OR)</option>{typeof triggerLogic === 'string' && triggerLogic !== '' && triggerLogic !== 'or' && triggerLogic !== 'and' && <option value={triggerLogic}>Invalid saved value ({triggerLogic})</option>}{triggerLogic === '' && <option value={EMPTY_CHOICE} disabled>Invalid saved value (empty)</option>}<option value="or">Any (OR)</option><option value="and">All (AND)</option></select>{drafts[pathKey(triggerLogicPath)] && <FieldState entry={drafts[pathKey(triggerLogicPath)]} onRevert={() => revertField(triggerLogicPath)} onRetry={() => retryField(triggerLogicPath)} onResync={() => resyncField(triggerLogicPath)} errorId={fieldErrorId(triggerLogicPath)} />}</div>{action.triggerLogic === 'xor' && <div className="inline-field-error"><ExclamationTriangleIcon aria-hidden="true" />Use Any (OR) or All (AND); “xor” is not a supported trigger logic.</div>}</Disclosure></div>

        <div className="editor-section"><Disclosure title="Chaining" subtitle="Continue to another action after this step." open={false} onToggle={() => undefined}><div className="chain-field"><label htmlFor="next-action">Next action</label><p>Default next action applies only to the root step. Select an action from any group.</p><select id="next-action" aria-describedby={drafts[pathKey(actionPath('nextAction'))]?.error ? fieldErrorId(actionPath('nextAction')) : undefined} value={valueFor(actionPath('nextAction')) === null || valueFor(actionPath('nextAction')) === undefined ? NULL_CHOICE : valueFor(actionPath('nextAction')) === '' ? EMPTY_CHOICE : displayValue(valueFor(actionPath('nextAction')))} onChange={(event) => { const next = event.target.value === NULL_CHOICE ? null : event.target.value === EMPTY_CHOICE ? '' : event.target.value; void commitField(actionPath('nextAction'), next) }}><option value={NULL_CHOICE}>Default (use Defaults)</option><option value={EMPTY_CHOICE}>None</option>{actionOptions(snapshot, ['inserts', selectedName]).slice(1).map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}</select>{action.nextAction === 'does-not-exist' && <div className="inline-field-error"><ExclamationTriangleIcon aria-hidden="true" />The saved link “does-not-exist” is unavailable. Choose another action or None.</div>}{drafts[pathKey(actionPath('nextAction'))] && <FieldState entry={drafts[pathKey(actionPath('nextAction'))]} onRevert={() => revertField(actionPath('nextAction'))} onRetry={() => retryField(actionPath('nextAction'))} onResync={() => resyncField(actionPath('nextAction'))} errorId={fieldErrorId(actionPath('nextAction'))} />}</div></Disclosure></div>

        <div className="editor-section"><Disclosure title="Advanced payload syntax" subtitle="Keep richer placeholders and regex replacements intact." open={advancedOpen} onToggle={setAdvancedOpen}><div className="advanced-copy"><p>Use the raw text above for transforms, XML placeholders, and regex replacements. The editor does not expand placeholders against live app context.</p><a href="https://github.com/ognistik/macrowhisper/blob/main/docs/placeholders-and-context.md" target="_blank" rel="noreferrer">Read the placeholder reference <UpdateIcon aria-hidden="true" /></a></div></Disclosure></div>
      </div>
    </section>
  )
}

function textInputProps(value: FieldValue, onChange: (value: string) => void, onBlur: (value: string) => void) {
  return { value: displayValue(value), onChange: (event: ChangeEvent<HTMLInputElement>) => onChange(event.target.value), onBlur: (event: FocusEvent<HTMLInputElement>) => onBlur(event.target.value) }
}

function SourcePill({ source }: { source: 'custom' | 'inherited' | 'template' | 'invalid' }) {
  const label = source === 'custom' ? 'Custom override' : source === 'inherited' ? 'Inherits Defaults' : source === 'template' ? 'Built-in template' : 'Needs repair'
  return <span className={`source-pill source-${source}`}>{source === 'invalid' ? <ExclamationTriangleIcon aria-hidden="true" /> : source === 'template' ? <RocketIcon aria-hidden="true" /> : source === 'inherited' ? <ResetIcon aria-hidden="true" /> : <CheckIcon aria-hidden="true" />}{label}</span>
}

function FieldLifecycle({ status }: { status: 'idle' | 'saving' | 'saved' }) {
  if (status === 'idle') return null
  return <span className={`field-state field-state-${status === 'saving' ? 'saving' : 'saved'}`}>{status === 'saving' ? 'Saving…' : <><CheckIcon aria-hidden="true" /> Saved</>}</span>
}

function ChoiceCard({ selected, value, label, description, onClick }: { selected: boolean; value: string; label: string; description: string; onClick: () => void }) {
  return <button type="button" className={selected ? 'choice-card is-selected' : 'choice-card'} aria-pressed={selected} onClick={onClick}><span className="choice-radio" aria-hidden="true">{selected && <CheckIcon />}</span><span><strong>{label}</strong><small>{description}</small></span><code>{value}</code></button>
}

function OverrideField({ field, path, snapshot, value, entry, meta, onChoice, onText, onBlur, onRevert, onRetry, onResync }: { field: string; path: string[]; snapshot: ConfigSnapshot; value: FieldValue; entry?: DraftEntry; meta: { label: string; description: string }; onChoice: (value: FieldValue) => void; onText: (value: string) => void; onBlur: (value: string) => void; onRevert: () => void; onRetry: () => void; onResync: () => void }) {
  const state = <FieldState entry={entry} onRevert={onRevert} onRetry={onRetry} onResync={onResync} errorId={fieldErrorId(path)} />
  const inputId = path.join('-')
  const numberField = field === 'actionDelay' || field === 'restoreClipboardDelay' || field === 'scriptWaitTimeout'
  const [numberOpen, setNumberOpen] = useState(value !== null && value !== undefined)

  if (field === 'icon' || field === 'moveTo') {
    return <div className="override-field"><div className="override-label"><label htmlFor={inputId}>{meta.label}</label>{state}</div><p>{meta.description}</p><NullableTextControl kind={field} value={value} onChoice={onChoice} onText={onText} onBlur={onBlur} ariaLabel={meta.label} errorId={fieldErrorId(path)} /></div>
  }
  if (numberField) {
    const showingValue = numberOpen || (value !== null && value !== undefined)
    return <div className="override-field"><div className="override-label"><label htmlFor={inputId}>{meta.label}</label>{state}</div><p>{meta.description}</p><div className="override-control"><select aria-label={`${meta.label} inheritance`} value={showingValue ? 'value' : 'default'} onChange={(event) => { if (event.target.value === 'default') { setNumberOpen(false); onChoice(null) } else setNumberOpen(true) }}><option value="default">Default ({inheritedNumberDefaultText(snapshot, field)} s)</option><option value="value">Override</option></select>{showingValue && <input id={inputId} value={displayValue(value)} inputMode="decimal" onChange={(event) => onText(event.target.value)} onBlur={(event) => onBlur(event.target.value)} aria-label={meta.label} aria-describedby={entry?.error ? fieldErrorId(path) : undefined} />}<span className="unit">seconds</span></div></div>
  }
  if (booleanFields.has(field)) return <div className="override-field"><div className="override-label"><label htmlFor={inputId}>{meta.label}</label>{state}</div><p>{meta.description}</p><select id={inputId} aria-label={meta.label} aria-describedby={entry?.error ? fieldErrorId(path) : undefined} value={booleanValue(value)} onChange={(event) => onChoice(event.target.value === 'default' ? null : event.target.value === 'on')}><option value="default">Default ({inheritedBooleanDefaultText(snapshot, field)})</option><option value="on">{booleanText(field, true)}</option><option value="off">{booleanText(field, false)}</option></select></div>
  return null
}

function booleanValue(value: FieldValue): string {
  return value === null || value === undefined ? 'default' : value ? 'on' : 'off'
}

function Disclosure({ title, subtitle, open, onToggle, children }: { title: string; subtitle: string; open: boolean; onToggle: (open: boolean) => void; children: ReactNode }) {
  return <details className="disclosure" open={open} onToggle={(event) => onToggle((event.currentTarget as HTMLDetailsElement).open)}><summary><span><strong>{title}</strong><small>{subtitle}</small></span><ChevronDownIcon aria-hidden="true" /></summary><div className="disclosure-body">{children}</div></details>
}

function UnsupportedActionGroup({ group, snapshot }: { group: GroupDefinition; snapshot: ConfigSnapshot }) {
  return <div className="screen-content unsupported-screen"><div className="screen-intro"><div><p className="eyebrow">Action group</p><h1>{group.label}</h1><p className="screen-description">{group.description}</p></div><span className="coming-badge">Prototype scope</span></div><div className="unsupported-panel"><div className="unsupported-mark">{group.icon}</div><h2>{group.label} editing is next</h2><p>The fixture includes {Object.keys(snapshot[group.id]).length} {group.label.toLowerCase()} {Object.keys(snapshot[group.id]).length === 1 ? 'action' : 'actions'} so cross-action links and names can be reviewed from Defaults and Insert controls. Type-specific editors will reuse this transaction boundary.</p><div className="unsupported-grid"><div><strong>Already covered</strong><span>Names are included in fallback and next-action pickers.</span></div><div><strong>Preserved semantics</strong><span>Unsupported fields remain in the fixture payload and are not rewritten.</span></div></div></div></div>
}

function useModalBehavior(dialogRef: React.RefObject<HTMLElement | null>, initialRef: React.RefObject<HTMLElement | null>, onClose: () => void) {
  useEffect(() => {
    const dialog = dialogRef.current
    if (!dialog) return
    const previous = document.activeElement instanceof HTMLElement ? document.activeElement : null
    const focusable = () => Array.from(dialog.querySelectorAll<HTMLElement>('button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), a[href], [tabindex]:not([tabindex="-1"])'))
    const first = initialRef.current ?? focusable()[0]
    first?.focus()
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault()
        onClose()
        return
      }
      if (event.key !== 'Tab') return
      const items = focusable()
      if (items.length === 0) return
      const current = document.activeElement
      const index = items.indexOf(current as HTMLElement)
      const nextIndex = event.shiftKey
        ? (index <= 0 ? items.length - 1 : index - 1)
        : (index === items.length - 1 ? 0 : index + 1)
      if (index === -1 || (event.shiftKey && index === 0) || (!event.shiftKey && index === items.length - 1)) {
        event.preventDefault()
        items[nextIndex].focus()
      }
    }
    dialog.addEventListener('keydown', onKeyDown)
    return () => {
      dialog.removeEventListener('keydown', onKeyDown)
      previous?.focus()
    }
  }, [dialogRef, initialRef, onClose])
}

function DeleteDialog({ name, references, onClose, onDelete, busy }: { name: string; references: string[]; onClose: () => void; onDelete: () => void; busy: boolean }) {
  const dialogRef = useRef<HTMLDialogElement>(null)
  const cancelRef = useRef<HTMLButtonElement>(null)
  useModalBehavior(dialogRef, cancelRef, onClose)
  return <div className="modal-backdrop" role="presentation"><dialog open ref={dialogRef} className="modal" aria-modal="true" aria-labelledby="delete-title" aria-describedby="delete-description"><div className="modal-icon"><TrashIcon aria-hidden="true" /></div><h2 id="delete-title">Delete “{name}”?</h2><p id="delete-description">This removes the Insert from the fixture configuration. The action will be blocked while another action or Defaults points to it.</p>{references.length > 0 && <div className="reference-block" role="alert"><strong>Change these references first</strong>{references.map((reference) => <span key={reference}>{reference}</span>)}</div>}<div className="modal-actions"><button ref={cancelRef} type="button" className="quiet-button" onClick={onClose}>Cancel</button><button type="button" className="danger-button filled" disabled={references.length > 0 || busy} onClick={onDelete}>{busy ? 'Deleting…' : 'Delete Insert'}</button></div></dialog></div>
}

function NavigationDialog({ target, onClose, onDiscard }: { target: string; onClose: () => void; onDiscard: () => void }) {
  const dialogRef = useRef<HTMLDialogElement>(null)
  const keepRef = useRef<HTMLButtonElement>(null)
  useModalBehavior(dialogRef, keepRef, onClose)
  return <div className="modal-backdrop" role="presentation"><dialog open ref={dialogRef} className="modal small-modal" aria-modal="true" aria-labelledby="navigation-title" aria-describedby="navigation-description"><div className="modal-icon neutral"><ScissorsIcon aria-hidden="true" /></div><h2 id="navigation-title">Leave unsaved changes?</h2><p id="navigation-description">Your draft could not be acknowledged. Keep editing this action or discard the draft before opening “{target}”.</p><div className="modal-actions"><button ref={keepRef} type="button" className="quiet-button" onClick={onClose}>Keep editing</button><button type="button" className="danger-button filled" onClick={onDiscard}>Discard draft</button></div></dialog></div>
}

export { App }
export default App
