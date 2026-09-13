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
import { API_SESSION_STORAGE_KEY, ApiStore } from './store/apiStore'
import { FixtureStore } from './store/fixtureStore'
import type {
  ActionGroup,
  ConfigSnapshot,
  Edit,
  EditorStore,
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
  clipboardAttachments: { on: 'Enable attachments', off: 'Disable attachments' },
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
  clipboardAttachments: { label: 'Clipboard attachments', description: 'Allow supported files and images during handoff.' },
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
  clipboardAttachments: { label: 'Clipboard attachments', description: 'Override attachment handoff for this chain.' },
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
  { key: 'result', label: 'Raw dictation', hint: 'The unprocessed dictation result.' },
  { key: 'llmResult', label: 'Language-model result', hint: 'Only available when a language-model step produced a result.' },
  { key: 'selectedText', label: 'Selected text', hint: 'Text selected when recording started.' },
  { key: 'clipboardContext', label: 'Clipboard context', hint: 'Captured clipboard text and attachments.' },
  { key: 'frontApp', label: 'Front app', hint: 'The app that was frontmost for this action.' },
  { key: 'appContext', label: 'App context', hint: 'Accessible context from the front app.' },
  { key: 'appVocabulary', label: 'App vocabulary', hint: 'Likely terms from the front app.' },
  { key: 'actionResult', label: 'Action result', hint: 'Output from an earlier action in this chain.' },
]

const placeholderTransforms = [
  { key: 'uppercase', label: 'Uppercase', hint: 'Convert the result to uppercase.' },
  { key: 'lowercase', label: 'Lowercase', hint: 'Convert the result to lowercase.' },
  { key: 'trim', label: 'Trim whitespace', hint: 'Remove leading and trailing whitespace.' },
  { key: 'ensureSentence', label: 'Ensure sentence', hint: 'Normalize the result into a sentence.' },
]

interface ReplacementStage {
  find: string
  replace: string
}

interface EditablePlaceholder {
  start: number
  end: number
  raw: string
  prefixType?: 'json' | 'raw'
  key: string
  format?: string
  transformName?: string
  regexReplacements: ReplacementStage[]
}

const dateFormats = [
  { value: 'short', label: 'Short date' },
  { value: 'long', label: 'Long date' },
  { value: 'yyyy-MM-dd', label: 'YYYY-MM-DD' },
  { value: 'yyyy-MM-dd HH:mm', label: 'Date and time' },
]

const triggerFields = ['triggerVoice', 'triggerApps', 'triggerModes', 'triggerUrls']
const triggerLabels: Record<string, { label: string; description: string; placeholder: string }> = {
  triggerVoice: { label: 'Voice phrases', description: 'Match a spoken prefix, or switch to Raw regex for a regular expression.', placeholder: 'reply' },
  triggerApps: { label: 'Front apps', description: 'Match an app name or bundle ID. Mark a row as an exception to exclude it.', placeholder: 'Mail or com.apple.mail' },
  triggerModes: { label: 'Superwhisper modes', description: 'Match one or more configured mode names.', placeholder: 'writing' },
  triggerUrls: { label: 'Browser URLs', description: 'Match a domain or URL prefix.', placeholder: 'docs.example.com' },
}

interface TriggerToken {
  value: string
  excluded: boolean
}

function splitTriggerTokens(raw: string, field: string): string[] {
  const tokens: string[] = []
  let token = ''
  let inRegex = false
  for (const character of raw) {
    if (field === 'triggerVoice' && character === '=' && token.endsWith('=')) inRegex = !inRegex
    if (character === '|' && !inRegex) {
      tokens.push(token)
      token = ''
    } else {
      token += character
    }
  }
  tokens.push(token)
  return tokens
}

function parseTriggerTokens(raw: string, field: string): TriggerToken[] {
  return splitTriggerTokens(raw, field)
    .filter((token) => token !== '')
    .map((token) => ({ excluded: token.startsWith('!'), value: token.startsWith('!') ? token.slice(1) : token }))
}

function serializeTriggerTokens(tokens: TriggerToken[]): string {
  return tokens
    .map((token) => `${token.excluded ? '!' : ''}${token.value}`)
    .filter((token) => token !== '' && token !== '!')
    .join('|')
}

function isRawVoiceExpression(raw: string): boolean {
  const trimmed = raw.trim()
  return trimmed.startsWith('==') && trimmed.endsWith('==') && trimmed.length >= 4
}

function isStructuredTriggerExpression(raw: string, field: string): boolean {
  if (!raw) return true
  if (field === 'triggerVoice' && isRawVoiceExpression(raw)) return false
  if (raw.includes('==') || raw.startsWith('|') || raw.endsWith('|') || raw.includes('||')) return false
  return splitTriggerTokens(raw, field).every((token) => token !== '' && token !== '!')
}

function isEscapedAt(value: string, index: number): boolean {
  let slashes = 0
  for (let cursor = index - 1; cursor >= 0 && value[cursor] === '\\'; cursor -= 1) slashes += 1
  return slashes % 2 === 1
}

function splitAtFirstUnescapedDelimiter(value: string, delimiters: string[]): { head: string; tail: string } {
  const sorted = [...delimiters].sort((a, b) => b.length - a.length)
  for (let index = 0; index < value.length; index += 1) {
    if (isEscapedAt(value, index)) continue
    const delimiter = sorted.find((candidate) => value.startsWith(candidate, index))
    if (delimiter) return { head: value.slice(0, index), tail: value.slice(index) }
  }
  return { head: value, tail: '' }
}

function splitByUnescapedDoublePipe(value: string): string[] {
  const parts: string[] = []
  let start = 0
  for (let index = 0; index < value.length - 1; index += 1) {
    if (value[index] !== '|' || value[index + 1] !== '|' || isEscapedAt(value, index)) continue
    parts.push(value.slice(start, index))
    start = index + 2
    index += 1
  }
  parts.push(value.slice(start))
  return parts
}

function extractPlaceholderSegments(value: string): Array<{ start: number; end: number; content: string }> {
  const segments: Array<{ start: number; end: number; content: string }> = []
  let cursor = 0
  while (cursor < value.length) {
    let start = -1
    for (let index = cursor; index < value.length - 1; index += 1) {
      if (value[index] === '{' && value[index + 1] === '{' && !isEscapedAt(value, index)) {
        start = index
        break
      }
    }
    if (start < 0) break
    const contentStart = start + 2
    let closeStart = -1
    for (let index = contentStart; index < value.length - 1; index += 1) {
      if (value[index] !== '}' || value[index + 1] !== '}' || isEscapedAt(value, index)) continue
      let runEnd = index + 2
      while (runEnd < value.length && value[runEnd] === '}') runEnd += 1
      closeStart = runEnd - 2
      break
    }
    if (closeStart < 0) break
    const end = closeStart + 2
    segments.push({ start, end, content: value.slice(contentStart, closeStart) })
    cursor = end
  }
  return segments
}

function parseEditablePlaceholder(value: string, segment: { start: number; end: number; content: string }): EditablePlaceholder | null {
  let remaining = segment.content
  let prefixType: 'json' | 'raw' | undefined
  if (remaining.startsWith('json:')) {
    prefixType = 'json'
    remaining = remaining.slice(5)
  } else if (remaining.startsWith('raw:')) {
    prefixType = 'raw'
    remaining = remaining.slice(4)
  }

  let keyEnd = 0
  while (keyEnd < remaining.length && /[A-Za-z0-9_.]/.test(remaining[keyEnd])) keyEnd += 1
  if (keyEnd === 0) return null
  const key = remaining.slice(0, keyEnd)
  remaining = remaining.slice(keyEnd)

  let format: string | undefined
  if (remaining.startsWith(':') && !remaining.startsWith('::')) {
    remaining = remaining.slice(1)
    const split = splitAtFirstUnescapedDelimiter(remaining, ['::', '||'])
    const trimmed = split.head.trim()
    if (trimmed) format = trimmed
    remaining = split.tail
  }

  let transformName: string | undefined
  if (remaining.startsWith('::')) {
    remaining = remaining.slice(2)
    const split = splitAtFirstUnescapedDelimiter(remaining, ['||'])
    const trimmed = split.head.trim()
    if (trimmed) transformName = trimmed
    remaining = split.tail
  }

  const regexReplacements: ReplacementStage[] = []
  if (remaining.startsWith('||')) {
    const parts = splitByUnescapedDoublePipe(remaining.slice(2))
    if (parts.length % 2 !== 0) return null
    for (let index = 0; index < parts.length; index += 2) {
      regexReplacements.push({ find: parts[index], replace: parts[index + 1] })
    }
    remaining = ''
  }
  if (remaining !== '') return null

  const knownSource = placeholders.some((source) => source.key === key) || key === 'date'
  const knownTransform = !transformName || placeholderTransforms.some((transform) => transform.key === transformName)
  // A raw or newer syntax is intentionally not editable in the inspector. It
  // remains available in the textarea so opening the helper never rewrites it.
  if (!knownSource || !knownTransform || (key === 'date' && !format)) return null

  return {
    start: segment.start,
    end: segment.end,
    raw: value.slice(segment.start, segment.end),
    prefixType,
    key,
    format,
    transformName,
    regexReplacements,
  }
}

function placeholderAtCaret(value: string, caret: number): EditablePlaceholder | null {
  for (const segment of extractPlaceholderSegments(value)) {
    if (caret < segment.start || caret > segment.end) continue
    const parsed = parseEditablePlaceholder(value, segment)
    if (parsed) return parsed
  }
  return null
}

function rawRegexBody(raw: string): string {
  const trimmed = raw.trim()
  return isRawVoiceExpression(trimmed) ? trimmed.slice(2, -2) : raw
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
  if (overrideFields.every((field) => action[field] === null || action[field] === undefined)) return 'inherited'
  return 'custom'
}

/** Keep serialized sentinel names in the data model, but give them a human
 * label anywhere an action is presented as something a person can choose. */
function actionDisplayName(name: string, action?: InsertConfig): string {
  return action?.action === '.none' ? 'Do nothing' : name
}

function actionDisplayDetail(name: string, action: InsertConfig): string {
  if (action.action === '.autoPaste') return 'Built-in auto-paste'
  if (action.action === '.none') return `Built-in do-nothing template · stored as ${name}`
  return action.action.replace(/\s+/g, ' ').slice(0, 42) || 'Empty payload'
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

function numberDefaultText(field: string): string {
  const value = schemaDefault(field)
  return value === null || value === undefined || value === '' ? 'None' : String(value)
}

function inheritedNumberDefaultText(snapshot: ConfigSnapshot, field: string): string {
  const value = effectiveDefault(snapshot, field)
  return value === null || value === undefined || value === '' ? 'None' : String(value)
}

function effectiveValue(snapshot: ConfigSnapshot, valueFor: (path: string[]) => FieldValue, field: string): Scalar {
  void snapshot
  const value = valueFor(['defaults', field])
  return value === null || value === undefined ? schemaDefault(field) : value
}

function effectiveActionLabel(snapshot: ConfigSnapshot, valueFor: (path: string[]) => FieldValue, field: 'activeAction' | 'nextAction'): string {
  const name = displayValue(effectiveValue(snapshot, valueFor, field))
  if (!name) return field === 'activeAction' ? 'None' : 'Stop'
  for (const group of groups) {
    const action = snapshot[group.id][name]
    if (!action) continue
    if (action.action === '.autoPaste') return 'Built-in auto-paste'
    if (action.action === '.none') return 'Built-in do-nothing template'
    return actionDisplayName(name, action)
  }
  return name
}

function defaultSectionSummary(sectionKey: string, snapshot: ConfigSnapshot, valueFor: (path: string[]) => FieldValue): string {
  const bool = (field: string) => Boolean(effectiveValue(snapshot, valueFor, field))
  const text = (field: string) => displayValue(effectiveValue(snapshot, valueFor, field))
  switch (sectionKey) {
    case 'general':
      return `${effectiveActionLabel(snapshot, valueFor, 'activeAction')} · ${bool('disableUpdateCheck') ? 'Checks off' : 'Checks on'} · ${bool('muteNotifications') ? 'Notifications off' : 'Notifications on'}`
    case 'insertion':
      return `${bool('simEsc') ? 'Escape on' : 'Escape off'} · ${bool('simKeypress') ? 'Type characters' : 'Paste text'} · Smart text ${bool('smartCasing') && bool('smartPunctuation') && bool('smartSpacing') ? 'on' : 'custom'}`
    case 'clipboard':
      return `${bool('restoreClipboard') ? 'Restore clipboard' : 'Keep new clipboard'} · ${bool('clipboardStacking') ? 'Stacking on' : 'Stacking off'} · ${bool('clipboardAttachments') ? 'Attachments on' : 'Attachments off'}`
    case 'recordings': {
      const watch = text('watch') || 'Built-in watch folder'
      const history = effectiveValue(snapshot, valueFor, 'history')
      return `Watch ${watch} · ${history === null || history === '' ? 'Keep forever' : `${history} days`}`
    }
    case 'scripts':
      return `${bool('scriptAsync') ? 'Scripts continue immediately' : 'Wait for scripts'} · ${bool('muteTriggers') ? 'Triggers muted' : 'Triggers evaluated'}`
    case 'advanced':
      return `${text('icon') || 'No icon'} · ${bool('autoUpdateConfig') ? 'Startup updates on' : 'Startup updates off'} · ${bool('redactedLogs') ? 'Logs redacted' : 'Logs include values'}`
    default:
      return ''
  }
}

function defaultSectionDraftStatus(section: { fields: string[] }, drafts: Record<string, DraftEntry>): string {
  const statuses = section.fields.map((field) => drafts[pathKey(['defaults', field])]?.status).filter(Boolean)
  if (statuses.includes('error')) return 'Not saved'
  if (statuses.includes('saving')) return 'Saving…'
  if (statuses.includes('dirty')) return 'Unsaved'
  if (statuses.includes('saved')) return 'Saved'
  return ''
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
  const options: SelectOption[] = [{ value: '', label: 'Do nothing' }]
  const names = getAllActionNames(snapshot)
    .filter((item) => !(currentPath && item.group === currentPath[0] && item.name === currentPath[1]))
    .sort((a, b) => a.name.localeCompare(b.name))
  for (const item of names) {
    const action = (snapshot[item.group] as Record<string, InsertConfig>)[item.name]
    const name = actionDisplayName(item.name, action)
    const storedName = name === item.name ? '' : ` (${item.name})`
    const builtInLabel = action.action === '.autoPaste'
      ? 'Built-in auto-paste'
      : action.action === '.none'
        ? 'Built-in do-nothing template'
        : name
    const visibleName = action.action === '.autoPaste' || action.action === '.none' ? builtInLabel : `${builtInLabel}${storedName}`
    const storedNameSuffix = action.action === '.none' ? ` · ${item.name}` : ''
    options.push({ value: item.name, label: `${visibleName}${storedNameSuffix} · ${groupById.get(item.group)?.shortLabel ?? item.group}` })
  }
  return options
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
  const choices: ThemeChoice[] = ['system', 'light', 'dark']
  const move = (choice: ThemeChoice) => {
    onChange(choice)
    requestAnimationFrame(() => document.getElementById(`theme-${choice}`)?.focus())
  }
  return (
    <div className="theme-control" role="radiogroup" aria-label="Appearance">
      {choices.map((choice, index) => (
        <button
          type="button"
          key={choice}
          id={`theme-${choice}`}
          role="radio"
          className={theme === choice ? 'theme-option is-selected' : 'theme-option'}
          aria-checked={theme === choice}
          tabIndex={theme === choice ? 0 : -1}
          onClick={() => move(choice)}
          onKeyDown={(event) => {
            const direction = event.key === 'ArrowRight' || event.key === 'ArrowDown' ? 1 : event.key === 'ArrowLeft' || event.key === 'ArrowUp' ? -1 : event.key === 'Home' ? -index : event.key === 'End' ? choices.length - 1 - index : 0
            if (!direction && event.key !== 'Home' && event.key !== 'End') return
            event.preventDefault()
            move(choices[(index + direction + choices.length) % choices.length])
          }}
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

function hasLiveEditorCredential(): boolean {
  if (typeof window === 'undefined') return false
  if (/(?:^#|[&#])(bootstrap|bootstrapToken|token|macrowhisperBootstrap)=/.test(window.location.hash)) return true
  try {
    return window.sessionStorage.getItem(API_SESSION_STORAGE_KEY) !== null
  } catch {
    return false
  }
}

function createDefaultStore(): EditorStore {
  const port = typeof window === 'undefined' ? '' : window.location.port
  if (port !== '' && (port !== '5173' || hasLiveEditorCredential())) return new ApiStore()
  return new FixtureStore('populated', { writeDelayMs: 120 })
}

function App({ store: suppliedStore }: { store?: EditorStore } = {}) {
  const store = useMemo(() => suppliedStore ?? createDefaultStore(), [suppliedStore])
  const fixtureStore = store instanceof FixtureStore ? store : null
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
    const lifecycleStore = store as EditorStore & { start?: () => Promise<ConfigSnapshot>; dispose?: () => void }
    void lifecycleStore.start?.()
    return () => lifecycleStore.dispose?.()
  }, [store])

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
    const currentScenario = fixtureStore?.getScenario?.()
    if (currentScenario && scenario !== currentScenario) setScenario(currentScenario)
  }, [screen, selectedName, snapshot, scenario, fixtureStore])

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
    if (!fixtureStore) return
    epochRef.current += 1
    setScenario(next)
    fixtureStore.setScenario(next)
    draftsRef.current = {}
    setDrafts({})
    setLifecycleError('')
    setLifecycleStatus('idle')
    setScreen('defaults')
    setSelectedName(next === 'empty' ? '' : 'dailyNotes')
    setMobileActionView('list')
    setMobileNavOpen(false)
  }, [fixtureStore])

  const reconnectFixture = () => {
    fixtureStore?.reconnect()
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
            <div className="connection-line"><span className={`status-dot status-${snapshot.runtime.status}`} aria-hidden="true" /><span>{snapshot.runtime.status === 'connected' ? (fixtureStore ? 'Fixture connected' : 'Connected') : snapshot.runtime.status === 'loading' ? 'Connecting' : snapshot.runtime.status === 'fallback' ? 'Runtime fallback' : 'Disconnected'}</span></div>
            <p>{snapshot.runtime.message}</p>
            {fixtureStore && snapshot.runtime.status === 'disconnected' && <button type="button" className="quiet-button compact connection-action" onClick={reconnectFixture}>Reconnect fixture</button>}
          </div>
          <div className="path-block"><span>CONFIGURATION</span><code>{snapshot.path}</code></div>
          <ThemeControl theme={theme} onChange={setTheme} />
        </div>
      </aside>

      <main className="main-panel">
        <header className="topbar">
          <button ref={mobileMenuRef} type="button" className="mobile-menu-button" aria-expanded={mobileNavOpen} aria-controls="configuration-navigation" onClick={() => setMobileNavOpen(true)}><GearIcon aria-hidden="true" /> Menu</button>
          <div className="breadcrumb"><span>Macrowhisper</span><span className="breadcrumb-separator">/</span><span>{screen === 'defaults' ? 'Defaults' : currentGroup?.label}</span>{currentAction && <><span className="breadcrumb-separator">/</span><strong title={selectedName}>{actionDisplayName(selectedName, currentAction)}</strong></>}</div>
          <div className="topbar-tools">
            <div className="revision-chip" title={`${snapshot.revision.generation} · version ${snapshot.revision.version}`} aria-live="polite"><span className="revision-dot" />{pendingCount > 0 ? ` Saving${pendingCount > 1 ? ` ${pendingCount}` : ''}…` : ` Revision ${snapshot.revision.version}`}</div>
            {fixtureStore && <label className="scenario-picker">Fixture
              <select aria-label="Fixture scenario" value={scenario} onChange={(event) => handleScenario(event.target.value as StoreScenario)}>
                <option value="populated">Populated</option><option value="invalid">Invalid field</option><option value="conflict">Conflict</option><option value="empty">Empty Inserts</option><option value="disconnected">Disconnected</option>
              </select>
              <ChevronDownIcon aria-hidden="true" />
            </label>}
          </div>
        </header>

        {snapshot.disk.status !== 'valid' && <DiskBanner snapshot={snapshot} />}
        {snapshot.runtime.status === 'disconnected' && <div className="inline-banner warning"><ExclamationTriangleIcon aria-hidden="true" /><div><strong>Working offline</strong><span>{fixtureStore ? 'Drafts stay in this tab until the fixture adapter reconnects. Retry after choosing a connected scenario.' : 'Open a fresh editor link with macrowhisper --editor to reconnect. Unsaved drafts remain in this tab.'}</span></div></div>}

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
          <UnsupportedActionGroup group={currentGroup!} snapshot={snapshot} fixtureBacked={Boolean(fixtureStore)} />
        )}
      </main>

      {isNarrow && mobileNavOpen && <button type="button" className="mobile-nav-backdrop" tabIndex={-1} aria-label="Close navigation" onClick={() => setMobileNavOpen(false)} />}

      {deleteOpen && <DeleteDialog name={actionDisplayName(selectedName, currentAction)} storedName={selectedName} fixtureBacked={Boolean(fixtureStore)} references={inboundReferences(snapshot, selectedName)} onClose={() => setDeleteOpen(false)} onDelete={() => void deleteInsert()} busy={lifecycleStatus === 'saving'} />}
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
  const [openSection, setOpenSection] = useState<string | null>('general')
  const sectionProps = (section: { key: string; label: string; description: string; fields: string[] }) => ({
    section,
    open: openSection === section.key,
    onToggle: (nextOpen: boolean) => setOpenSection(nextOpen ? section.key : null),
  })
  return (
    <div className="screen-content defaults-screen">
      <div className="screen-intro">
        <div><h1>Defaults</h1><p className="screen-description">Set the behavior shared by every action. Open a section only when you need to change it.</p></div>
        <div className="intro-meta"><span className="meta-label">CONFIG VERSION</span><strong>2</strong><span className="meta-label">WATCH FOLDER</span><code>{snapshot.defaults.watch ?? '~/Documents/superwhisper'}</code></div>
      </div>
      <div className="defaults-grid">
        <div className="defaults-column">
          {defaultFieldGroups.slice(0, 3).map((section) => <DefaultSection key={section.key} {...sectionProps(section)} snapshot={snapshot} valueFor={valueFor} drafts={drafts} textHandlers={textHandlers} setDraftValue={setDraftValue} commitField={commitField} revertField={revertField} retryField={retryField} resyncField={resyncField} />)}
        </div>
        <div className="defaults-column">
          {defaultFieldGroups.slice(3).map((section) => <DefaultSection key={section.key} {...sectionProps(section)} snapshot={snapshot} valueFor={valueFor} drafts={drafts} textHandlers={textHandlers} setDraftValue={setDraftValue} commitField={commitField} revertField={revertField} retryField={retryField} resyncField={resyncField} />)}
        </div>
      </div>
    </div>
  )
}

interface DefaultSectionProps extends DefaultsScreenProps {
  section: { key: string; label: string; description: string; fields: string[] }
  open: boolean
  onToggle: (open: boolean) => void
}

function DefaultSection({ section, open, onToggle, snapshot, valueFor, drafts, textHandlers, setDraftValue, commitField, revertField, retryField, resyncField }: DefaultSectionProps) {
  const effectiveSummary = defaultSectionSummary(section.key, snapshot, valueFor)
  const draftStatus = defaultSectionDraftStatus(section, drafts)
  const summary = draftStatus ? `${effectiveSummary} · ${draftStatus}` : effectiveSummary
  return (
    <section className="settings-section">
      <Disclosure title={section.label} subtitle={section.description} meta={summary} open={open} onToggle={onToggle}>
        <div className="field-list">
          {section.fields.map((field) => <DefaultField key={field} field={field} snapshot={snapshot} valueFor={valueFor} drafts={drafts} textHandlers={textHandlers} setDraftValue={setDraftValue} commitField={commitField} revertField={revertField} retryField={retryField} resyncField={resyncField} />)}
        </div>
      </Disclosure>
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
  collapseDefault = false,
}: {
  kind: 'icon' | 'moveTo'
  value: FieldValue
  onChoice: (value: FieldValue) => void
  onText: (value: string) => void
  onBlur: (value: string) => void
  ariaLabel: string
  errorId?: string
  collapseDefault?: boolean
}) {
  const isMove = kind === 'moveTo'
  const isCustomValue = typeof value === 'string' && value !== '' && (!isMove || value !== '.delete')
  const [customOpen, setCustomOpen] = useState(isCustomValue)
  const mode = customOpen || isCustomValue ? 'custom' : isMove && value === '.delete' ? 'delete' : collapseDefault ? 'empty' : value === null || value === undefined ? 'default' : 'empty'
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
        {!collapseDefault && <option value="default">Default</option>}
        {!isMove && <option value="empty">No icon{collapseDefault ? ' (Built-in)' : ''}</option>}
        {isMove && <option value="empty">Keep recording{collapseDefault ? ' (Built-in)' : ''}</option>}
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
    const rootReferenceValue = value === null || value === undefined || value === '' ? EMPTY_CHOICE : displayValue(value)
    const emptyChoiceLabel = field === 'activeAction' ? 'No fallback action' : 'No next action'
    return <SettingRow label={meta.label} description={meta.description} state={<FieldState entry={entry} {...saveProps} />} controlId={field}><select id={field} aria-describedby={entry?.error ? fieldErrorId(path) : undefined} aria-label={meta.label} value={rootReferenceValue} onChange={(event) => {
      const next = event.target.value === EMPTY_CHOICE ? '' : event.target.value
      onChoice(next)
    }}><option value={EMPTY_CHOICE}>{emptyChoiceLabel}</option>{options.slice(1).map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}</select></SettingRow>
  }

  if (field === 'icon' || field === 'moveTo') {
    return <SettingRow label={meta.label} description={meta.description} state={<FieldState entry={entry} {...saveProps} />}><NullableTextControl kind={field} value={value} onChoice={onChoice} onText={(next) => setDraftValue(path, next)} onBlur={(next) => { if (entry?.status === 'dirty' || next !== displayValue(readPath(snapshot, path))) void commitField(path, next) }} ariaLabel={meta.label} errorId={fieldErrorId(path)} collapseDefault /></SettingRow>
  }

  if (field === 'watch' || field === 'clipboardIgnore' || field === 'bypassModes') {
    const props = textHandlers(path)
    return <SettingRow label={meta.label} description={meta.description} state={<FieldState entry={entry} {...saveProps} />} controlId={field}><div className="setting-input-stack"><div className="input-with-affordance"><input id={field} {...props} aria-label={meta.label} aria-describedby={entry?.error ? fieldErrorId(path) : undefined} placeholder={field === 'watch' ? '~/superwhisper' : ''} />{field === 'watch' && <span className="input-affordance"><Link1Icon aria-hidden="true" /></span>}</div><button type="button" className="text-button reset-field-button" onClick={() => onChoice(null)} disabled={value === null || value === undefined}>Reset to default</button></div></SettingRow>
  }

  if (field === 'history' || field === 'actionDelay' || field === 'returnDelay' || field === 'restoreClipboardDelay' || field === 'scheduledActionTimeout' || field === 'scriptWaitTimeout' || field === 'clipboardBuffer') {
    const props = textHandlers(path)
    return <SettingRow label={meta.label} description={meta.description} state={<FieldState entry={entry} {...saveProps} />} controlId={field}><div className="setting-input-stack"><div className="input-with-unit"><input id={field} {...props} aria-label={meta.label} aria-describedby={entry?.error ? fieldErrorId(path) : undefined} inputMode="decimal" type="text" placeholder={field === 'history' ? 'Keep forever' : numberDefaultText(field)} />{field !== 'history' && <span>{numberUnits[field]}</span>}</div><button type="button" className="text-button reset-field-button" onClick={() => onChoice(null)} disabled={value === null || value === undefined}>{field === 'history' ? 'Keep forever' : 'Reset to default'}</button></div></SettingRow>
  }

  if (booleanFields.has(field)) {
    const builtIn = schemaDefault(field) === true
    const selected = value === null || value === undefined ? (builtIn ? 'on' : 'off') : value ? 'on' : 'off'
    return <SettingRow label={meta.label} description={meta.description} state={<FieldState entry={entry} {...saveProps} />} controlId={field}><select id={field} aria-describedby={entry?.error ? fieldErrorId(path) : undefined} aria-label={meta.label} value={selected} onChange={(event) => onChoice(event.target.value === 'on')}><option value="on">{booleanText(field, true)}{builtIn ? ' (Built-in)' : ''}</option><option value="off">{booleanText(field, false)}{!builtIn ? ' (Built-in)' : ''}</option></select></SettingRow>
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

function ActionList({ snapshot, selectedName, search, setSearch, onSelect, onCreate, createOpen, duplicateOpen, createName, createPayload, setCreateName, setCreatePayload, onSubmitCreate, onCancelCreate, lifecycleError, lifecycleStatus }: ActionListProps) {
  const names = Object.keys(snapshot.inserts).filter((name) => name.toLocaleLowerCase().includes(search.toLocaleLowerCase()))
  return (
    <aside className="action-list" aria-label="Insert actions">
      <div className="action-list-heading"><div><h1>Inserts</h1></div><span className="section-count">{Object.keys(snapshot.inserts).length}</span></div>
      <p className="list-description">Text actions for pasting or typing into the focused app.</p>
      <div className="action-list-tools"><label className="search-field"><MagnifyingGlassIcon aria-hidden="true" /><span className="sr-only">Search Inserts</span><input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Search actions" /></label><div className="list-action-buttons"><button type="button" className="primary-button compact" onClick={onCreate}><PlusIcon aria-hidden="true" /> New Insert</button></div></div>
      {(createOpen || duplicateOpen) && <div className="create-panel"><strong className="create-panel-title">{duplicateOpen ? 'Duplicate Insert' : 'New Insert'}</strong><label>Name<input autoFocus value={createName} onChange={(event) => setCreateName(event.target.value)} onKeyDown={(event) => { if (event.key === 'Enter') onSubmitCreate() }} placeholder="e.g. meetingNotes" /></label>{!duplicateOpen && <label>Payload<textarea value={createPayload} onChange={(event) => setCreatePayload(event.target.value)} rows={3} /></label>}<div className="panel-actions"><button type="button" className="quiet-button" onClick={onCancelCreate}>Cancel</button><button type="button" className="primary-button compact" onClick={onSubmitCreate} disabled={lifecycleStatus === 'saving'}>{lifecycleStatus === 'saving' ? 'Creating…' : duplicateOpen ? 'Duplicate' : 'Create Insert'}</button></div>{lifecycleError && <div className="panel-error"><ExclamationTriangleIcon aria-hidden="true" />{lifecycleError}</div>}</div>}
      <div className="action-items" role="listbox" aria-label="Available Inserts">
        {names.map((name) => {
          const action = snapshot.inserts[name]
          return <button type="button" role="option" aria-selected={name === selectedName} className={name === selectedName ? 'action-item is-selected' : 'action-item'} key={name} onClick={() => onSelect(name)}><span className="action-item-icon">{action.icon || '·'}</span><span className="action-item-copy"><strong title={name}>{actionDisplayName(name, action)}</strong><small>{actionDisplayDetail(name, action)}</small></span></button>
        })}
        {names.length === 0 && <div className="list-empty"><MagnifyingGlassIcon aria-hidden="true" /><span>{search ? 'No matching Inserts' : 'No Inserts yet'}</span>{!search && <button type="button" className="text-button" onClick={onCreate}>Create one</button>}</div>}
      </div>
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
  const [activePlaceholder, setActivePlaceholder] = useState<EditablePlaceholder | null>(null)
  const [pendingOverrides, setPendingOverrides] = useState<string[]>([])
  const [pendingConditions, setPendingConditions] = useState<string[]>([])
  const [conditionAdvanced, setConditionAdvanced] = useState(false)
  const [conditionOpen, setConditionOpen] = useState(source === 'invalid')
  const [insertionOpen, setInsertionOpen] = useState(false)
  const [chainingOpen, setChainingOpen] = useState(false)
  const composingRef = useRef(false)
  const deferredBlurRef = useRef(false)
  const textareaRef = useRef<HTMLTextAreaElement>(null)
  const selectionRef = useRef({ start: payload.length, end: payload.length })
  const boundaryRef = useRef<HTMLDivElement>(null)
  const conditionPath = actionPath('inputCondition')
  const conditionRaw = displayValue(valueFor(conditionPath))
  const conditionValues = parseCondition(conditionRaw)
  const conditionAnalysis = analyzeCondition(conditionRaw)

  const rememberSelection = () => {
    const element = textareaRef.current
    if (element) {
      selectionRef.current = { start: element.selectionStart, end: element.selectionEnd }
      setActivePlaceholder(placeholderAtCaret(displayValue(valueFor(payloadPath)), element.selectionStart))
    }
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

  const insertExpression = (insertion: string) => {
    const element = textareaRef.current
    const { start, end } = selectionRef.current
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
      setActivePlaceholder(placeholderAtCaret(inserted ? element.value : next, caret))
    })
  }

  const updatePlaceholder = (next: EditablePlaceholder) => {
    const currentPayload = displayValue(valueFor(payloadPath))
    const prefix = next.prefixType ? `${next.prefixType}:` : ''
    const format = next.key === 'date' ? `:${next.format || 'short'}` : ''
    const transform = next.transformName ? `::${next.transformName}` : ''
    const replacements = next.regexReplacements
      .map((stage) => `||${regexBuilderPart(stage.find)}||${regexBuilderPart(stage.replace)}`)
      .join('')
    const raw = `{{${prefix}${next.key}${format}${transform}${replacements}}}`
    const updatedPayload = `${currentPayload.slice(0, next.start)}${raw}${currentPayload.slice(next.end)}`
    const updated = { ...next, end: next.start + raw.length, raw }
    setDraftValue(payloadPath, updatedPayload)
    setActivePlaceholder(updated)
    requestAnimationFrame(() => {
      const caret = updated.end - 2
      textareaRef.current?.setSelectionRange(caret, caret)
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
    setPendingConditions((current) => current.filter((item) => item !== field))
  }

  const actionMeta = actionFieldLabels
  const conditionUnsupported = Object.keys(conditionValues).some((field) => !conditionFieldsByGroup.inserts.includes(field))
  const conditionHasIssue = conditionAnalysis.malformed || conditionAnalysis.repeated.length > 0 || conditionUnsupported
  const conditionSummary = conditionRaw
    ? `${Object.keys(conditionValues).length} rule${Object.keys(conditionValues).length === 1 ? '' : 's'}${conditionHasIssue ? ' · review raw' : ''}`
    : 'Always'
  const overrideCount = overrideFields.filter((field) => valueFor(actionPath(field)) !== null && valueFor(actionPath(field)) !== undefined).length
  const configuredOverrides = overrideFields.filter((field) => field in actionMeta && valueFor(actionPath(field)) !== null && valueFor(actionPath(field)) !== undefined)
  const visibleOverrides = [...configuredOverrides, ...pendingOverrides.filter((field) => !configuredOverrides.includes(field))]
  const availableOverrides = overrideFields.filter((field) => field in actionMeta && !visibleOverrides.includes(field))
  const configuredConditions = conditionFieldsByGroup.inserts.filter((field) => conditionValues[field])
  const visibleConditions = [...configuredConditions, ...pendingConditions.filter((field) => !configuredConditions.includes(field))]
  const availableConditions = conditionFieldsByGroup.inserts.filter((field) => !visibleConditions.includes(field))

  return (
    <section className="insert-editor">
      <div className="editor-header">
        <button type="button" className="back-button mobile-action-back" onClick={onBack}><ArrowLeftIcon aria-hidden="true" /> Inserts</button>
        <div className="editor-header-actions"><SourcePill source={source} /><button type="button" className="quiet-button" onClick={onDuplicate}><CopyIcon aria-hidden="true" /> Duplicate</button><button type="button" className="quiet-button danger-button" onClick={onDelete} disabled={payload === '.autoPaste'} title={payload === '.autoPaste' ? 'The .autoPaste built-in cannot be deleted' : undefined}><TrashIcon aria-hidden="true" /> Delete</button></div>
      </div>
      <div className="editor-scroll">
        <div className="editor-title-row"><div><h1 title={selectedName}>{actionDisplayName(selectedName, action)}</h1><p className="screen-description">{groupById.get('inserts')?.description}</p></div><div className="editor-revision"><span>Revision</span><strong>{snapshot.revision.version}</strong></div></div>

        {source === 'invalid' && <div className="field-alert"><ExclamationTriangleIcon aria-hidden="true" /><div><strong>This action has invalid configuration.</strong><span>Fix the highlighted fields before saving another change. Existing text is preserved so you can repair it deliberately.</span></div></div>}
        {source === 'template' && <div className="template-callout"><div className="template-icon"><RocketIcon aria-hidden="true" /></div><div><strong>{payloadMode === 'autoPaste' ? 'Auto-paste template' : 'Do nothing template'}</strong><span>{payloadMode === 'autoPaste' ? 'Macrowhisper’s built-in paste behavior supplies the payload and insertion details at runtime.' : 'This action intentionally performs no payload operation. Its triggers and chain settings can still apply.'}</span></div></div>}

        <div className="editor-section identity-section"><div className="section-heading"><div><h2>Identity</h2><p>Names are unique across Inserts, URLs, Shortcuts, Shell, and AppleScript.</p></div></div><div className="rename-row"><label htmlFor="insert-name">Action name</label><div className="rename-control"><input id="insert-name" value={renameValue} onChange={(event) => setRenameValue(event.target.value)} onKeyDown={(event) => { if (event.key === 'Enter') onRename() }} onBlur={() => { if (renameValue.trim() !== selectedName) onRename() }} /><button type="button" className="quiet-button" onClick={onRename} disabled={lifecycleStatus === 'saving' || renameValue.trim() === selectedName}><Pencil1Icon aria-hidden="true" /> Rename</button><FieldLifecycle status={lifecycleStatus} /></div></div>{lifecycleError && <div className="inline-field-error"><ExclamationTriangleIcon aria-hidden="true" />{lifecycleError}</div>}</div>

        <div className="editor-section payload-section">
          <div className="section-heading payload-heading">
            <div><h2>Payload</h2><p>Choose a built-in mode or write Custom text. Placeholder helpers only appear for Custom text.</p></div>
            <a className="section-heading-link" href="https://github.com/ognistik/macrowhisper/blob/main/docs/placeholders-and-context.md" target="_blank" rel="noreferrer">Placeholder syntax reference <UpdateIcon aria-hidden="true" /></a>
          </div>
          <div className="payload-boundary" ref={boundaryRef} onBlur={onPayloadBlur}>
            <div className="payload-toolbar">
              <div className="mode-label">{payloadMode === 'text' ? 'Custom text' : payloadMode === 'autoPaste' ? 'Auto-paste' : 'Do nothing'}</div>
              <div className="placeholder-menu"><button type="button" className="toolbar-button" aria-haspopup="menu" aria-expanded={placeholderOpen} disabled={payloadMode !== 'text'} title={payloadMode === 'text' ? undefined : 'Choose Custom text to insert a placeholder'} onMouseDown={(event) => event.preventDefault()} onClick={() => { rememberSelection(); setPlaceholderOpen((open) => !open) }}><PlusIcon aria-hidden="true" /> Insert placeholder <ChevronDownIcon aria-hidden="true" /></button>{placeholderOpen && <PlaceholderMenu onInsert={insertExpression} onKeyDown={onPlaceholderKey} />}</div>
            </div>
            <div className="built-in-choice-row" role="radiogroup" aria-label="Payload mode"><ChoiceCard selected={payloadMode === 'autoPaste'} value=".autoPaste" label="Auto-paste" description="Use the built-in paste flow." onClick={() => setActionChoice('autoPaste')} /><ChoiceCard selected={payloadMode === 'none'} value=".none" displayValue="No payload" label="Do nothing" description="Keep triggers and chain settings." onClick={() => setActionChoice('none')} /><ChoiceCard selected={payloadMode === 'text'} value="text" label="Custom text" description="Edit the payload below." onClick={() => setActionChoice('text')} /></div>
            {payloadMode === 'text' && <><textarea ref={textareaRef} value={payload} aria-label="Insert payload" aria-describedby={payloadEntry?.error ? fieldErrorId(payloadPath) : undefined} rows={8} onChange={(event) => { setDraftValue(payloadPath, event.target.value); setActivePlaceholder(placeholderAtCaret(event.target.value, event.target.selectionStart)) }} onSelect={rememberSelection} onKeyUp={rememberSelection} onFocus={rememberSelection} onCompositionStart={() => { composingRef.current = true }} onCompositionEnd={(event) => {
          composingRef.current = false
          if (deferredBlurRef.current) {
            deferredBlurRef.current = false
            void commitField(payloadPath, event.currentTarget.value)
          }
        }} placeholder="Type the text to insert…" />{activePlaceholder && <PlaceholderInspector placeholder={activePlaceholder} onChange={updatePlaceholder} />}<div className="payload-footer"><span>{payload.length} characters</span><FieldState entry={payloadEntry} onRevert={() => revertField(payloadPath)} onRetry={() => retryField(payloadPath)} onResync={() => resyncField(payloadPath)} errorId={fieldErrorId(payloadPath)} /></div></>}
          </div>
        </div>

        <div className="editor-section"><Disclosure title="Insertion behavior" subtitle="Overrides inherited Defaults for this Insert." meta={`${overrideCount} override${overrideCount === 1 ? '' : 's'}${overrideCount === 0 ? ' · Using Defaults' : ''}`} open={insertionOpen} onToggle={setInsertionOpen}>
          {visibleOverrides.length === 0 && <div className="section-empty"><strong>Using Defaults</strong><span>This Insert has no insertion overrides.</span></div>}
          <div className="configured-list">{visibleOverrides.map((field) => {
            const configured = configuredOverrides.includes(field)
            return <div className="configured-item" key={field}><fieldset className="template-field" disabled={payloadMode !== 'text' && (field === 'simEsc' || field === 'restoreClipboard')}><OverrideField field={field} path={actionPath(field)} snapshot={snapshot} value={valueFor(actionPath(field))} entry={drafts[pathKey(actionPath(field))]} meta={actionMeta[field]} onChoice={(value) => { void commitField(actionPath(field), value); if (value !== null && value !== undefined) setPendingOverrides((current) => current.filter((item) => item !== field)) }} onText={(value) => setDraftValue(actionPath(field), value)} onBlur={(value) => { commitIfChanged(actionPath(field), value); setPendingOverrides((current) => current.filter((item) => item !== field)) }} onRevert={() => revertField(actionPath(field))} onRetry={() => retryField(actionPath(field))} onResync={() => resyncField(actionPath(field))} />{payloadMode !== 'text' && (field === 'simEsc' || field === 'restoreClipboard') && <p className="template-note">{payloadMode === 'autoPaste' ? 'Template: Off outside text fields; Defaults inside text fields.' : 'Template: Off.'} Stored override is retained.</p>}</fieldset><button type="button" className="text-button remove-configured" onClick={() => { setPendingOverrides((current) => current.filter((item) => item !== field)); if (configured) void commitField(actionPath(field), null) }}><Cross2Icon aria-hidden="true" /> {configured ? 'Use Defaults' : 'Cancel'}</button></div>
          })}</div>
          {availableOverrides.length > 0 && <label className="add-setting-control"><span className="sr-only">Add override</span><PlusIcon aria-hidden="true" /><select aria-label="Add override" value="" onChange={(event) => { const field = event.target.value; if (field) setPendingOverrides((current) => [...current, field]) }}><option value="">Add override…</option>{availableOverrides.map((field) => <option key={field} value={field}>{actionMeta[field].label}</option>)}</select></label>}
          <div className="template-note"><MinusCircledIcon aria-hidden="true" /> Removing an override restores Use Defaults. Empty strings remain explicit values.</div>
        </Disclosure></div>

        <div className="editor-section"><Disclosure title="Conditions" subtitle="Apply supported settings inside or outside text fields." meta={conditionSummary} open={conditionOpen} onToggle={setConditionOpen}>
          <div className="condition-intro">Add a rule only when a setting should behave differently inside or outside a text field.</div>
          {conditionHasIssue && <div className="inline-field-error"><ExclamationTriangleIcon aria-hidden="true" />This saved expression contains {conditionAnalysis.malformed ? 'an invalid token' : conditionAnalysis.repeated.length > 0 ? `repeated token${conditionAnalysis.repeated.length === 1 ? '' : 's'}` : 'a token this editor cannot represent'}. It stays intact until you deliberately edit Advanced raw mode.</div>}
          <fieldset className="template-field" disabled={payloadMode !== 'text' || conditionHasIssue || conditionAdvanced}>{payloadMode !== 'text' && <p className="template-note">The built-in mode supplies its own conditions. Your stored expression is retained for Custom text.</p>}{conditionHasIssue && !conditionAdvanced && <p className="template-note">Structured controls are paused until you enable Edit raw expression.</p>}{visibleConditions.length === 0 && !conditionHasIssue && <div className="section-empty"><strong>Always</strong><span>No conditional behavior is configured.</span></div>}<div className="condition-list">{visibleConditions.map((field) => <div className="condition-row" key={field}><div><strong>{field === 'action' ? 'Payload' : actionMeta[field]?.label ?? field}</strong><span>{field === 'action' ? 'Text or built-in action value' : 'Choose where this rule applies'}</span></div><select aria-label={`Condition for ${field}`} value={conditionValues[field] ?? ''} onChange={(event) => setConditionMode(field, event.target.value as 'inside' | 'outside')}><option value="" disabled>Choose…</option><option value="inside">Only in a text field</option><option value="outside">Only outside text fields</option></select><button type="button" className="icon-button" aria-label={`Remove condition for ${field}`} onClick={() => setConditionMode(field, 'always')}><Cross2Icon aria-hidden="true" /></button></div>)}</div>{availableConditions.length > 0 && !conditionHasIssue && <label className="add-setting-control"><span className="sr-only">Add condition</span><PlusIcon aria-hidden="true" /><select aria-label="Add condition" value="" onChange={(event) => { const field = event.target.value; if (field) setPendingConditions((current) => [...current, field]) }}><option value="">Add condition…</option>{availableConditions.map((field) => <option key={field} value={field}>{field === 'action' ? 'Payload' : actionMeta[field]?.label ?? field}</option>)}</select></label>}</fieldset>
          <div className="generated-expression"><span>Generated expression</span><code>{conditionRaw || 'Always'}</code></div><label className="advanced-toggle"><input type="checkbox" checked={conditionAdvanced} onChange={(event) => setConditionAdvanced(event.target.checked)} /> Edit raw expression</label><div className="raw-expression"><input aria-label="Advanced input condition" readOnly={!conditionAdvanced} value={conditionRaw} aria-describedby={drafts[pathKey(conditionPath)]?.error ? fieldErrorId(conditionPath) : undefined} onChange={(event) => { if (conditionAdvanced) setDraftValue(conditionPath, event.target.value) }} onBlur={(event) => { if (conditionAdvanced) commitIfChanged(conditionPath, event.target.value) }} /><span>{conditionAdvanced ? 'Raw mode is deliberate; existing text is preserved until you edit it.' : 'Read-only preview. Enable Edit raw expression only for syntax this builder cannot represent.'}</span><FieldState entry={drafts[pathKey(conditionPath)]} onRevert={() => revertField(conditionPath)} onRetry={() => retryField(conditionPath)} onResync={() => resyncField(conditionPath)} errorId={fieldErrorId(conditionPath)} /></div>
        </Disclosure></div>

        <TriggerEditor action={action} selectedName={selectedName} actionPath={actionPath} drafts={drafts} valueFor={valueFor} setDraftValue={setDraftValue} commitIfChanged={commitIfChanged} commitField={commitField} revertField={revertField} retryField={retryField} resyncField={resyncField} />

        <div className="editor-section"><Disclosure title="Chaining" subtitle="Continue to another action after this step." meta={valueFor(actionPath('nextAction')) ? 'Linked' : 'No next action'} open={chainingOpen} onToggle={setChainingOpen}><div className="chain-field"><label htmlFor="next-action">Next action</label><p>The Defaults next action applies only to the root step. Select an action from any group.</p><select id="next-action" aria-describedby={drafts[pathKey(actionPath('nextAction'))]?.error ? fieldErrorId(actionPath('nextAction')) : undefined} value={valueFor(actionPath('nextAction')) === null || valueFor(actionPath('nextAction')) === undefined ? NULL_CHOICE : valueFor(actionPath('nextAction')) === '' ? EMPTY_CHOICE : displayValue(valueFor(actionPath('nextAction')))} onChange={(event) => { const next = event.target.value === NULL_CHOICE ? null : event.target.value === EMPTY_CHOICE ? '' : event.target.value; void commitField(actionPath('nextAction'), next) }}><option value={NULL_CHOICE}>Use Defaults next action</option><option value={EMPTY_CHOICE}>Stop chain</option>{actionOptions(snapshot, ['inserts', selectedName]).slice(1).map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}</select>{action.nextAction === 'does-not-exist' && <div className="inline-field-error"><ExclamationTriangleIcon aria-hidden="true" />The saved link “does-not-exist” is unavailable. Choose another action or Stop chain.</div>}{drafts[pathKey(actionPath('nextAction'))] && <FieldState entry={drafts[pathKey(actionPath('nextAction'))]} onRevert={() => revertField(actionPath('nextAction'))} onRetry={() => retryField(actionPath('nextAction'))} onResync={() => resyncField(actionPath('nextAction'))} errorId={fieldErrorId(actionPath('nextAction'))} />}</div></Disclosure></div>
      </div>
    </section>
  )
}

function PlaceholderMenu({ onInsert, onKeyDown }: { onInsert: (expression: string) => void; onKeyDown: (event: React.KeyboardEvent<HTMLDivElement>) => void }) {
  const [dateFormat, setDateFormat] = useState('short')
  return (
    <div className="placeholder-popover" role="menu" aria-label="Insert placeholder" onKeyDown={onKeyDown}>
      <div className="placeholder-group"><span className="placeholder-group-title">Sources</span>{placeholders.map((item) => <button type="button" role="menuitem" key={item.key} onMouseDown={(event) => event.preventDefault()} onClick={() => onInsert(`{{${item.key}}}`)}><span className="placeholder-chip">{'{{'}{item.key}{'}}'}</span><span><strong>{item.label}</strong><small>{item.hint}</small></span></button>)}</div>
      <div className="placeholder-group date-placeholder"><span className="placeholder-group-title">Date</span><label>Date format<select aria-label="Date format" value={dateFormat} onChange={(event) => setDateFormat(event.target.value)}>{dateFormats.map((format) => <option key={format.value} value={format.value}>{format.label}</option>)}</select></label><button type="button" role="menuitem" onMouseDown={(event) => event.preventDefault()} onClick={() => onInsert(`{{date:${dateFormat}}}`)}><span className="placeholder-chip">{'{{date:'}{dateFormat}{'}}'}</span><span><strong>Insert date</strong><small>Choose the date format before inserting.</small></span></button></div>
    </div>
  )
}

function regexBuilderPart(value: string): string {
  const normalized = value
  let encoded = ''
  for (let index = 0; index < normalized.length; index += 1) {
    const character = normalized[index]
    if (character === '|' && normalized[index + 1] === '|') {
      let precedingSlashes = 0
      for (let slashIndex = encoded.length - 1; slashIndex >= 0 && encoded[slashIndex] === '\\'; slashIndex -= 1) precedingSlashes += 1
      if (precedingSlashes % 2 === 0) {
        encoded += '\\|\\|'
        index += 1
        continue
      }
    }
    encoded += character
  }
  return encoded
}

function PlaceholderInspector({ placeholder, onChange }: { placeholder: EditablePlaceholder; onChange: (placeholder: EditablePlaceholder) => void }) {
  const updateStage = (index: number, next: ReplacementStage) => onChange({ ...placeholder, regexReplacements: placeholder.regexReplacements.map((stage, stageIndex) => stageIndex === index ? next : stage) })
  return <section className="placeholder-inspector" aria-label="Edit placeholder">
    <div className="placeholder-inspector-heading"><div><strong>Edit placeholder</strong><span>Changes update this placeholder in the payload.</span></div><code>{placeholder.raw}</code></div>
    <div className="placeholder-inspector-grid">
      <label>Source<select aria-label="Placeholder source" value={placeholder.key} onChange={(event) => onChange({ ...placeholder, key: event.target.value, format: event.target.value === 'date' ? placeholder.format || 'short' : undefined })}>{placeholders.map((item) => <option key={item.key} value={item.key}>{item.label}</option>)}<option value="date">Date</option></select></label>
      <label>Transform<select aria-label="Placeholder transform" value={placeholder.transformName ?? ''} onChange={(event) => onChange({ ...placeholder, transformName: event.target.value || undefined })}><option value="">No transform</option>{placeholderTransforms.map((item) => <option key={item.key} value={item.key}>{item.label}</option>)}</select></label>
      {placeholder.key === 'date' && <label className="date-format-field">Date format<input aria-label="Placeholder date format" value={placeholder.format ?? 'short'} onChange={(event) => onChange({ ...placeholder, format: event.target.value })} /></label>}
    </div>
    <div className="replacement-editor"><div className="replacement-editor-heading"><div><strong>Regex replacements</strong><span>{placeholder.regexReplacements.length === 0 ? 'No replacements' : `${placeholder.regexReplacements.length} stage${placeholder.regexReplacements.length === 1 ? '' : 's'}`}</span></div><button type="button" className="text-button" onClick={() => onChange({ ...placeholder, regexReplacements: [...placeholder.regexReplacements, { find: '', replace: '' }] })}><PlusIcon aria-hidden="true" /> Add replacement</button></div>
      {placeholder.regexReplacements.map((stage, index) => <div className="replacement-inline-row" key={index}><strong>Stage {index + 1}</strong><label>Find<input aria-label={`Find pattern ${index + 1}`} value={stage.find} onChange={(event) => updateStage(index, { ...stage, find: event.target.value })} placeholder="e.g. \\.$" /></label><label>Replace with<textarea aria-label={`Replacement text ${index + 1}`} value={stage.replace} onChange={(event) => updateStage(index, { ...stage, replace: event.target.value })} rows={2} placeholder="Leave empty to remove" /></label><button type="button" className="icon-button" aria-label={`Remove replacement ${index + 1}`} onClick={() => onChange({ ...placeholder, regexReplacements: placeholder.regexReplacements.filter((_, stageIndex) => stageIndex !== index) })}><Cross2Icon aria-hidden="true" /></button></div>)}
    </div>
    <div className="generated-expression"><span>Generated syntax</span><code>{placeholder.raw}</code></div>
  </section>
}

function TriggerTokenRows({ field, rows, onChange, onAdd, onRemove }: { field: string; rows: TriggerToken[]; onChange: (index: number, next: TriggerToken) => void; onAdd: () => void; onRemove: (index: number) => void }) {
  return <div className="trigger-token-list">{rows.map((row, index) => <div className="trigger-token-row" key={`${field}-${index}`}><input aria-label={`${triggerLabels[field].label} ${index + 1}`} value={row.value} onChange={(event) => onChange(index, { ...row, value: event.target.value })} placeholder={triggerLabels[field].placeholder} /><label className="token-exception"><input type="checkbox" checked={row.excluded} onChange={(event) => onChange(index, { ...row, excluded: event.target.checked })} /> Exclude</label>{rows.length > 1 && <button type="button" className="icon-button" aria-label={`Remove ${triggerLabels[field].label} ${index + 1}`} onClick={() => onRemove(index)}><Cross2Icon aria-hidden="true" /></button>}</div>)}<button type="button" className="text-button add-trigger-button" onClick={onAdd}><PlusIcon aria-hidden="true" /> Add {field === 'triggerVoice' ? 'phrase' : field === 'triggerApps' ? 'app' : field === 'triggerModes' ? 'mode' : 'URL'}</button></div>
}

interface TriggerEditorProps {
  action: InsertConfig
  selectedName: string
  actionPath: (field: string) => string[]
  drafts: Record<string, DraftEntry>
  valueFor: (path: string[]) => FieldValue
  setDraftValue: (path: string[], value: FieldValue) => void
  commitIfChanged: (path: string[], value: FieldValue) => void
  commitField: (path: string[], value: FieldValue) => Promise<boolean>
  revertField: (path: string[]) => void
  retryField: (path: string[]) => void
  resyncField: (path: string[]) => void
}

function TriggerEditor({ action, selectedName, actionPath, drafts, valueFor, setDraftValue, commitIfChanged, commitField, revertField, retryField, resyncField }: TriggerEditorProps) {
  const [open, setOpen] = useState(false)
  const [pendingFields, setPendingFields] = useState<string[]>([])
  const [voiceMode, setVoiceMode] = useState<'prefix' | 'regex' | 'advanced'>(() => {
    const raw = displayValue(action.triggerVoice)
    return isRawVoiceExpression(raw) ? 'regex' : isStructuredTriggerExpression(raw, 'triggerVoice') ? 'prefix' : 'advanced'
  })
  const [voiceAdvancedOptIn, setVoiceAdvancedOptIn] = useState(false)
  const [rawModes, setRawModes] = useState<Record<string, boolean>>({})
  const [rows, setRows] = useState<Record<string, TriggerToken[]>>(() => Object.fromEntries(triggerFields.map((field) => [field, parseTriggerTokens(displayValue(valueFor(actionPath(field))), field)])))
  const rawSignature = triggerFields.map((field) => displayValue(valueFor(actionPath(field)))).join('\u001e')
  useEffect(() => {
    setRows(Object.fromEntries(triggerFields.map((field) => [field, parseTriggerTokens(displayValue(valueFor(actionPath(field))), field)])))
    const voice = displayValue(valueFor(actionPath('triggerVoice')))
    setVoiceMode(isRawVoiceExpression(voice) ? 'regex' : isStructuredTriggerExpression(voice, 'triggerVoice') ? 'prefix' : 'advanced')
    setVoiceAdvancedOptIn(false)
  // rawSignature changes only after a saved/external value changes; row edits are deliberate and reparse losslessly.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedName, rawSignature])

  const updateRows = (field: string, nextRows: TriggerToken[]) => {
    setRows((current) => ({ ...current, [field]: nextRows }))
    setDraftValue(actionPath(field), serializeTriggerTokens(nextRows))
  }
  const triggerIssue = triggerFields.some((field) => {
    const raw = displayValue(valueFor(actionPath(field)))
    if (!raw) return false
    if (field === 'triggerVoice') return !isStructuredTriggerExpression(raw, field) && !isRawVoiceExpression(raw) && !(voiceMode === 'advanced' && voiceAdvancedOptIn)
    return !isStructuredTriggerExpression(raw, field) && !rawModes[field]
  })
  const configuredCount = triggerFields.reduce((count, field) => count + (displayValue(valueFor(actionPath(field))) ? 1 : 0), 0)
  const configuredFields = triggerFields.filter((field) => displayValue(valueFor(actionPath(field))))
  const visibleFields = [...configuredFields, ...pendingFields.filter((field) => !configuredFields.includes(field))]
  const availableFields = triggerFields.filter((field) => !visibleFields.includes(field))
  const logic = displayValue(valueFor(actionPath('triggerLogic')))
  const summary = configuredCount === 0
    ? 'No triggers'
    : configuredCount === 1
      ? '1 configured'
      : `${configuredCount} configured · ${logic === 'and' ? 'All (AND)' : 'Any (OR)'}`
  const stateFor = (field: string) => {
    const path = actionPath(field)
    return <FieldState entry={drafts[pathKey(path)]} onRevert={() => revertField(path)} onRetry={() => retryField(path)} onResync={() => resyncField(path)} errorId={fieldErrorId(path)} />
  }
  return <div className="editor-section"><Disclosure title="Triggers" subtitle="Match a phrase, app, mode, or URL." meta={summary} open={open} onToggle={setOpen}>
    <p className="trigger-priority"><strong>Matching priority</strong> Voice phrase → Superwhisper mode → browser URL → front app. Multiple configured fields follow Trigger logic below.</p>
    {visibleFields.length === 0 && <div className="section-empty"><strong>No triggers</strong><span>This Insert is available as a fallback or chain step.</span></div>}
    <div className="trigger-grid">{visibleFields.map((field) => {
      const path = actionPath(field)
      const raw = displayValue(valueFor(path))
      const isVoice = field === 'triggerVoice'
      const structured = isStructuredTriggerExpression(raw, field)
      const rawMode = rawModes[field] || (!structured && !isVoice)
      return <div className="trigger-field configured-item" key={field}>
        <div className="trigger-field-heading"><label htmlFor={`${field}-raw`}>{triggerLabels[field].label}</label><div className="trigger-field-actions">{stateFor(field)}<button type="button" className="icon-button" aria-label={`Remove ${triggerLabels[field].label}`} onClick={() => { setPendingFields((current) => current.filter((item) => item !== field)); setRows((current) => ({ ...current, [field]: [] })); if (raw) void commitField(path, '') }}><Cross2Icon aria-hidden="true" /></button></div></div>
        <p>{triggerLabels[field].description}</p>
        {isVoice && <label className="trigger-mode">Mode<select aria-label="Voice trigger mode" value={voiceMode} onChange={(event) => { const next = event.target.value as 'prefix' | 'regex' | 'advanced'; setVoiceMode(next); setVoiceAdvancedOptIn(next === 'advanced') }}><option value="prefix">Prefix phrases</option><option value="regex">Raw regex</option><option value="advanced">Advanced raw</option></select></label>}
        {isVoice && voiceMode === 'regex' ? <><input id={`${field}-raw`} aria-label="Voice raw regex" value={rawRegexBody(raw)} onChange={(event) => setDraftValue(path, `==${event.target.value}==`)} onBlur={(event) => { commitIfChanged(path, `==${event.target.value}==`); setPendingFields((current) => current.filter((item) => item !== field)) }} placeholder="^(reply|respond)\\s+(.+)$" /><small className="trigger-help">Stored as <code>==…==</code> so the expression is treated as regex.</small></> : isVoice && voiceMode === 'advanced' ? <><textarea id={`${field}-raw`} aria-label="Advanced voice trigger" value={raw} onChange={(event) => setDraftValue(path, event.target.value)} onBlur={(event) => { commitIfChanged(path, event.target.value); setPendingFields((current) => current.filter((item) => item !== field)) }} rows={2} /><small className="trigger-help">Raw syntax is preserved until you intentionally edit it.</small></> : rawMode ? <><textarea id={`${field}-raw`} aria-label={`Advanced ${triggerLabels[field].label}`} readOnly={!rawModes[field]} value={raw} onChange={(event) => { if (rawModes[field]) setDraftValue(path, event.target.value) }} onBlur={(event) => { if (rawModes[field]) commitIfChanged(path, event.target.value) }} rows={2} /><label className="advanced-toggle"><input type="checkbox" checked={Boolean(rawModes[field])} onChange={(event) => setRawModes((current) => ({ ...current, [field]: event.target.checked }))} /> Advanced raw mode</label><small className="trigger-help">This expression cannot be represented as token rows until you opt into raw editing.</small></> : <><TriggerTokenRows field={field} rows={rows[field] ?? []} onChange={(index, next) => updateRows(field, (rows[field] ?? []).map((row, rowIndex) => rowIndex === index ? next : row))} onAdd={() => setRows((current) => ({ ...current, [field]: [...(current[field] ?? []), { value: '', excluded: false }] }))} onRemove={(index) => updateRows(field, (rows[field] ?? []).filter((_, rowIndex) => rowIndex !== index))} />{structured && <label className="advanced-toggle"><input type="checkbox" checked={Boolean(rawModes[field])} onChange={(event) => setRawModes((current) => ({ ...current, [field]: event.target.checked }))} /> Advanced raw mode</label>}</>}
      </div>
    })}</div>
    {availableFields.length > 0 && <label className="add-setting-control"><span className="sr-only">Add trigger</span><PlusIcon aria-hidden="true" /><select aria-label="Add trigger" value="" onChange={(event) => { const field = event.target.value; if (!field) return; setPendingFields((current) => [...current, field]); setRows((current) => ({ ...current, [field]: current[field]?.length ? current[field] : [{ value: '', excluded: false }] })) }}><option value="">Add trigger…</option>{availableFields.map((field) => <option key={field} value={field}>{triggerLabels[field].label}</option>)}</select></label>}
    {configuredCount >= 2 && <div className="logic-row"><div><strong>Trigger logic</strong><span>How configured trigger types combine when more than one is present.</span></div><select aria-label="Trigger logic" value={valueFor(actionPath('triggerLogic')) === null || valueFor(actionPath('triggerLogic')) === undefined ? NULL_CHOICE : valueFor(actionPath('triggerLogic')) === '' ? EMPTY_CHOICE : displayValue(valueFor(actionPath('triggerLogic')))} onChange={(event) => { const next = event.target.value === NULL_CHOICE ? null : event.target.value === EMPTY_CHOICE ? '' : event.target.value; void commitField(actionPath('triggerLogic'), next) }}><option value={NULL_CHOICE}>Use Defaults (Any OR)</option>{typeof action.triggerLogic === 'string' && action.triggerLogic !== '' && action.triggerLogic !== 'or' && action.triggerLogic !== 'and' && <option value={action.triggerLogic}>Invalid saved value ({action.triggerLogic})</option>}{action.triggerLogic === '' && <option value={EMPTY_CHOICE} disabled>Invalid saved value (empty)</option>}<option value="or">Any (OR)</option><option value="and">All (AND)</option></select>{stateFor('triggerLogic')}</div>}
    {triggerIssue && <div className="inline-field-error"><ExclamationTriangleIcon aria-hidden="true" />A saved trigger expression needs Advanced raw mode before it can be edited as text.</div>}{action.triggerLogic === 'xor' && <div className="inline-field-error"><ExclamationTriangleIcon aria-hidden="true" />Use Any (OR) or All (AND); “xor” is not a supported trigger logic.</div>}
  </Disclosure></div>
}

function SourcePill({ source }: { source: 'custom' | 'inherited' | 'template' | 'invalid' }) {
  const label = source === 'custom' ? 'Custom override' : source === 'inherited' ? 'Inherits Defaults' : source === 'template' ? 'Built-in template' : 'Needs repair'
  return <span className={`source-pill source-${source}`}>{source === 'invalid' ? <ExclamationTriangleIcon aria-hidden="true" /> : source === 'template' ? <RocketIcon aria-hidden="true" /> : source === 'inherited' ? <ResetIcon aria-hidden="true" /> : <CheckIcon aria-hidden="true" />}{label}</span>
}

function FieldLifecycle({ status }: { status: 'idle' | 'saving' | 'saved' }) {
  if (status === 'idle') return null
  return <span className={`field-state field-state-${status === 'saving' ? 'saving' : 'saved'}`}>{status === 'saving' ? 'Saving…' : <><CheckIcon aria-hidden="true" /> Saved</>}</span>
}

function ChoiceCard({ selected, value, displayValue: visibleValue = value, label, description, onClick }: { selected: boolean; value: string; displayValue?: string; label: string; description: string; onClick: () => void }) {
  return <button type="button" role="radio" className={selected ? 'choice-card is-selected' : 'choice-card'} aria-checked={selected} tabIndex={selected ? 0 : -1} onClick={onClick} onKeyDown={(event) => {
    if (!['ArrowRight', 'ArrowDown', 'ArrowLeft', 'ArrowUp', 'Home', 'End'].includes(event.key)) return
    const group = event.currentTarget.parentElement
    const options = group ? Array.from(group.querySelectorAll<HTMLButtonElement>('[role="radio"]')) : []
    const index = options.indexOf(event.currentTarget)
    if (index < 0 || options.length === 0) return
    const direction = event.key === 'ArrowRight' || event.key === 'ArrowDown' ? 1 : event.key === 'ArrowLeft' || event.key === 'ArrowUp' ? -1 : event.key === 'Home' ? -index : options.length - 1 - index
    event.preventDefault()
    const next = options[(index + direction + options.length) % options.length]
    next?.click()
    next?.focus()
  }}><span className="choice-radio" aria-hidden="true">{selected && <CheckIcon />}</span><span><strong>{label}</strong><small>{description}</small></span><code>{visibleValue}</code></button>
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
    return <div className="override-field"><div className="override-label"><label htmlFor={inputId}>{meta.label}</label>{state}</div><p>{meta.description}</p><div className="override-control"><select aria-label={`${meta.label} inheritance`} value={showingValue ? 'value' : 'default'} onChange={(event) => { if (event.target.value === 'default') { setNumberOpen(false); onChoice(null) } else setNumberOpen(true) }}><option value="default">Use Defaults ({inheritedNumberDefaultText(snapshot, field)} s)</option><option value="value">Override</option></select>{showingValue && <input id={inputId} value={displayValue(value)} inputMode="decimal" onChange={(event) => onText(event.target.value)} onBlur={(event) => onBlur(event.target.value)} aria-label={meta.label} aria-describedby={entry?.error ? fieldErrorId(path) : undefined} />}<span className="unit">seconds</span></div></div>
  }
  if (booleanFields.has(field)) {
    const inherited = effectiveDefault(snapshot, field) === true
    const selected = value === null || value === undefined ? inherited : value === true
    const pinnedToCurrentDefault = typeof value === 'boolean' && value === inherited
    return <div className="override-field"><div className="override-label"><label htmlFor={inputId}>{meta.label}</label>{state}</div><p>{meta.description}</p><div className="setting-input-stack"><select id={inputId} aria-label={meta.label} aria-describedby={entry?.error ? fieldErrorId(path) : undefined} value={selected ? 'on' : 'off'} onChange={(event) => { const next = event.target.value === 'on'; onChoice(next === inherited ? null : next) }}><option value="on">{booleanText(field, true)}{inherited ? ' · Use Defaults' : ''}</option><option value="off">{booleanText(field, false)}{!inherited ? ' · Use Defaults' : ''}</option></select>{pinnedToCurrentDefault && <button type="button" className="text-button reset-field-button" onClick={() => onChoice(null)}>Use Defaults</button>}</div></div>
  }
  return null
}

function Disclosure({ title, subtitle, meta, open, onToggle, children }: { title: string; subtitle: string; meta?: ReactNode; open: boolean; onToggle: (open: boolean) => void; children: ReactNode }) {
  return <details className="disclosure" open={open} onToggle={(event) => onToggle((event.currentTarget as HTMLDetailsElement).open)}><summary><span><strong>{title}</strong><small>{subtitle}</small></span><span className="disclosure-summary-meta">{meta}</span><ChevronDownIcon aria-hidden="true" /></summary><div className="disclosure-body">{children}</div></details>
}

function UnsupportedActionGroup({ group, snapshot, fixtureBacked }: { group: GroupDefinition; snapshot: ConfigSnapshot; fixtureBacked: boolean }) {
  const count = Object.keys(snapshot[group.id]).length
  const groupName = group.label === 'URLs' ? 'URL' : group.label
  const noun = `${groupName} ${count === 1 ? 'action' : 'actions'}`
  return <div className="screen-content unsupported-screen"><div className="screen-intro"><div><h1>{group.label}</h1><p className="screen-description">{group.description}</p></div><span className="coming-badge">{fixtureBacked ? 'Fixture scope' : 'Read-only for now'}</span></div><div className="unsupported-panel"><div className="unsupported-mark">{group.icon}</div><h2>{group.label} editing is next</h2><p>{fixtureBacked ? `The fixture includes ${count} ${noun} so cross-action links and names can be reviewed from Defaults and Insert controls.` : `This connected snapshot includes ${count} ${noun}. Cross-action links and names can be reviewed from Defaults and Insert controls while type-specific editing is prepared.`} Type-specific editors will reuse this transaction boundary.</p><div className="unsupported-grid"><div><strong>Already covered</strong><span>Names are included in fallback and next-action pickers.</span></div><div><strong>Preserved semantics</strong><span>{fixtureBacked ? 'Unsupported fields remain in the fixture payload and are not rewritten.' : 'Unsupported fields remain in the server snapshot and are not rewritten.'}</span></div></div></div></div>
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

function DeleteDialog({ name, storedName, fixtureBacked, references, onClose, onDelete, busy }: { name: string; storedName?: string; fixtureBacked: boolean; references: string[]; onClose: () => void; onDelete: () => void; busy: boolean }) {
  const dialogRef = useRef<HTMLDialogElement>(null)
  const cancelRef = useRef<HTMLButtonElement>(null)
  useModalBehavior(dialogRef, cancelRef, onClose)
  return <div className="modal-backdrop" role="presentation"><dialog open ref={dialogRef} className="modal" aria-modal="true" aria-labelledby="delete-title" aria-describedby="delete-description"><div className="modal-icon"><TrashIcon aria-hidden="true" /></div><h2 id="delete-title">Delete “{name}”?</h2>{storedName && storedName !== name && <p className="stored-action-name">Stored action name: <code>{storedName}</code></p>}<p id="delete-description">This removes the Insert from the {fixtureBacked ? 'fixture configuration' : 'configuration'}. The action will be blocked while another action or Defaults points to it.</p>{references.length > 0 && <div className="reference-block" role="alert"><strong>Change these references first</strong>{references.map((reference) => <span key={reference}>{reference}</span>)}</div>}<div className="modal-actions"><button ref={cancelRef} type="button" className="quiet-button" onClick={onClose}>Cancel</button><button type="button" className="danger-button filled" disabled={references.length > 0 || busy} onClick={onDelete}>{busy ? 'Deleting…' : 'Delete Insert'}</button></div></dialog></div>
}

function NavigationDialog({ target, onClose, onDiscard }: { target: string; onClose: () => void; onDiscard: () => void }) {
  const dialogRef = useRef<HTMLDialogElement>(null)
  const keepRef = useRef<HTMLButtonElement>(null)
  useModalBehavior(dialogRef, keepRef, onClose)
  return <div className="modal-backdrop" role="presentation"><dialog open ref={dialogRef} className="modal small-modal" aria-modal="true" aria-labelledby="navigation-title" aria-describedby="navigation-description"><div className="modal-icon neutral"><ScissorsIcon aria-hidden="true" /></div><h2 id="navigation-title">Leave unsaved changes?</h2><p id="navigation-description">Your draft could not be acknowledged. Keep editing this action or discard the draft before opening “{target}”.</p><div className="modal-actions"><button ref={keepRef} type="button" className="quiet-button" onClick={onClose}>Keep editing</button><button type="button" className="danger-button filled" onClick={onDiscard}>Discard draft</button></div></dialog></div>
}

export { App }
export default App
