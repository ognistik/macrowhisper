import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react'
import type { ChangeEvent, FocusEvent, KeyboardEvent as ReactKeyboardEvent, ReactNode } from 'react'
import {
  ArrowDownIcon,
  ArrowLeftIcon,
  ArrowUpIcon,
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
  MagnifyingGlassIcon,
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
import { ActionPicker } from './components/ActionPicker'
import type { ActionPickerOption } from './components/ActionPicker'
import { API_SESSION_STORAGE_KEY, ApiStore } from './store/apiStore'
import { FixtureStore } from './store/fixtureStore'
import type {
  ActionGroup,
  ConfigSnapshot,
  Edit,
  EditorStore,
  FolderPickerPurpose,
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

const PreviewModeContext = createContext(false)

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
  savedAt?: number
}

interface GroupDefinition {
  id: ActionGroup
  label: string
  shortLabel: string
  icon: ReactNode
  description: string
}

type SelectOption = ActionPickerOption

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
    description: 'Shared behavior used unless an action overrides it.',
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

interface DefaultFieldLayoutGroup {
  key: string
  label: string
  description: string
  fields: string[]
}

const defaultFieldLayouts: Partial<Record<string, DefaultFieldLayoutGroup[]>> = {
  insertion: [
    { key: 'before', label: 'Before the action', description: 'Prepare the frontmost app before Macrowhisper inserts anything.', fields: ['simEsc', 'actionDelay'] },
    { key: 'text', label: 'Text handling', description: 'Choose how text is entered and cleaned up at the insertion boundary.', fields: ['simKeypress', 'smartCasing', 'smartPunctuation', 'smartSpacing'] },
    { key: 'after', label: 'After insertion', description: 'Optional behavior after the Insert finishes.', fields: ['simReturn', 'returnDelay'] },
  ],
  clipboard: [
    { key: 'capture', label: 'Capture and filter', description: 'Control which recent clipboard changes Macrowhisper can use as context.', fields: ['clipboardBuffer', 'clipboardIgnore'] },
    { key: 'context', label: 'Clipboard context', description: 'Choose how eligible text and attachments are collected for an action chain.', fields: ['clipboardStacking', 'clipboardAttachments'] },
    { key: 'restore', label: 'After the action chain', description: 'Choose whether and when the original clipboard returns.', fields: ['restoreClipboard', 'restoreClipboardDelay'] },
  ],
  scripts: [
    { key: 'execution', label: 'Script execution', description: 'Control whether script-like actions continue immediately or wait for completion.', fields: ['scriptAsync', 'scriptWaitTimeout'] },
    { key: 'matching', label: 'Trigger matching', description: 'Choose which Superwhisper modes participate and whether triggers run at all.', fields: ['bypassModes', 'muteTriggers'] },
  ],
}

export const DEFAULTS_OPEN_SECTION_STORAGE_KEY = 'macrowhisper-editor-defaults-open-section'

const defaultFieldLabels: Record<string, { label: string; description: string }> = {
  watch: { label: 'Superwhisper folder', description: 'The folder configured in Superwhisper. Macrowhisper watches its recordings subfolder.' },
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
  returnDelay: { label: 'Return delay', description: 'Default wait before pressing Return, including one-shot CLI auto-return.' },
  restoreClipboard: { label: 'Restore clipboard', description: 'Restore the original clipboard after the action chain.' },
  restoreClipboardDelay: { label: 'Clipboard restore delay', description: 'Default wait before restoring the original clipboard for an action flow.' },
  scheduledActionTimeout: { label: 'Scheduled action timeout', description: 'How long a scheduled action waits for a session.' },
  scriptAsync: { label: 'Run scripts asynchronously', description: 'Continue immediately instead of waiting for a script.' },
  scriptWaitTimeout: { label: 'Script wait timeout', description: 'Default maximum wait when a script action runs synchronously.' },
  clipboardStacking: { label: 'Stack clipboard context', description: 'Keep eligible clipboard changes in order.' },
  clipboardAttachments: { label: 'Clipboard attachments', description: 'Allow supported files and images during handoff.' },
  clipboardBuffer: { label: 'Clipboard buffer', description: 'Seconds of clipboard history captured before dictation.' },
  clipboardIgnore: { label: 'Ignore clipboard apps', description: 'App names or bundle IDs to ignore. Separate alternatives with |; regular expressions are supported. Leave empty to capture every app.' },
  bypassModes: { label: 'Bypass modes', description: 'Superwhisper modes to leave untouched. Separate exact names with |. Leave empty to process every mode.' },
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

interface PlaceholderSource {
  key: string
  label: string
  hint: string
}

const placeholderGroups: Array<{ label: string; items: PlaceholderSource[] }> = [
  {
    label: 'Results',
    items: [
      { key: 'swResult', label: 'Result', hint: 'Language-model result when available, otherwise raw dictation.' },
      { key: 'result', label: 'Raw dictation', hint: 'The unprocessed Superwhisper result.' },
      { key: 'llmResult', label: 'Language-model result', hint: 'Only when Superwhisper produced one.' },
    ],
  },
  {
    label: 'Captured context',
    items: [
      { key: 'selectedText', label: 'Selected text', hint: 'Text selected when recording started.' },
      { key: 'clipboardContext', label: 'Clipboard context', hint: 'Clipboard content captured for this session.' },
      { key: 'frontApp', label: 'Front app', hint: 'The app anchored to this action chain.' },
      { key: 'frontAppUrl', label: 'Front app URL', hint: 'The active URL when the front app is a supported browser.' },
      { key: 'appContext', label: 'App context', hint: 'Accessible context from the front app.' },
      { key: 'appVocabulary', label: 'App vocabulary', hint: 'Likely terms gathered from the front app.' },
    ],
  },
  {
    label: 'Workflow',
    items: [
      { key: 'actionResult', label: 'Action result', hint: 'Output from an earlier synchronous action.' },
      { key: 'folderName', label: 'Recording folder name', hint: 'Name of a completed recording folder.' },
      { key: 'folderPath', label: 'Recording folder path', hint: 'Path to a completed recording folder.' },
    ],
  },
]

const placeholders = placeholderGroups.flatMap((group) => group.items)

const placeholderTransforms = [
  { key: 'uppercase', label: 'UPPERCASE', group: 'Text case' },
  { key: 'lowercase', label: 'lowercase', group: 'Text case' },
  { key: 'uppercaseFirst', label: 'Uppercase first letter', group: 'Text case' },
  { key: 'lowercaseFirst', label: 'Lowercase first letter', group: 'Text case' },
  { key: 'trim', label: 'Trim whitespace', group: 'Text case' },
  { key: 'ensureSentence', label: 'Ensure sentence', group: 'Text case' },
  { key: 'camelCase', label: 'camelCase', group: 'Identifiers' },
  { key: 'pascalCase', label: 'PascalCase', group: 'Identifiers' },
  { key: 'snakeCase', label: 'snake_case', group: 'Identifiers' },
  { key: 'kebabCase', label: 'kebab-case', group: 'Identifiers' },
  { key: 'titleCase', label: 'Title case · automatic language', group: 'Titles' },
  { key: 'titleCase:en', label: 'Title case · English', group: 'Titles' },
  { key: 'titleCase:es', label: 'Title case · Spanish', group: 'Titles' },
  { key: 'titleCase:fr', label: 'Title case · French', group: 'Titles' },
  { key: 'titleCase:all', label: 'Title Case · every word', group: 'Titles' },
  { key: 'altCase', label: 'aLtErNaTiNg case', group: 'Specialized' },
  { key: 'altCase:upperFirst', label: 'AlTeRnAtInG case', group: 'Specialized' },
  { key: 'randomCase', label: 'Random case', group: 'Specialized' },
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
  xmlTag?: string
  format?: string
  transformName?: string
  regexReplacements: ReplacementStage[]
}

interface PlaceholderOccurrence {
  index: number
  start: number
  end: number
  raw: string
  label: string
  placeholder: EditablePlaceholder | null
}

const dateFormats = [
  { value: 'short', label: 'Short date', hint: 'Locale-aware compact date.' },
  { value: 'long', label: 'Long date', hint: 'Locale-aware written date.' },
  { value: 'yyyy-MM-dd', label: 'ISO date', hint: 'Year, month, and day.' },
  { value: 'yyyy-MM-dd HH:mm', label: 'Date and time', hint: 'Date plus 24-hour time.' },
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

/**
 * The v3 editor presents replacement helpers as text a person can edit:
 * Macrowhisper's canonical `\n` spelling is shown as an actual Return, while
 * a canonical `\\n` spelling remains visibly escaped as `\\n`. Keeping that
 * doubled spelling in the textarea means an unrelated edit cannot turn a
 * literal backslash+n into a Return on the next change event.
 */
function parseMacrowhisperReplacement(value: string): string {
  let parsed = ''
  let index = 0
  while (index < value.length) {
    if (value[index] !== '\\') {
      parsed += value[index]
      index += 1
      continue
    }

    const runStart = index
    while (index < value.length && value[index] === '\\') index += 1
    const slashCount = index - runStart
    if (index < value.length && value[index] === 'n') {
      if (slashCount % 2 === 1) {
        // Preserve any literal slash pairs in front of the newline while
        // presenting the odd token itself as an actual Return.
        parsed += '\\'.repeat(slashCount - 1)
        parsed += '\n'
      } else {
        // Even runs are already the stable, visibly escaped spelling for a
        // literal backslash+n in the helper field.
        parsed += '\\'.repeat(slashCount) + 'n'
      }
      index += 1
    } else {
      parsed += '\\'.repeat(slashCount)
    }
  }
  return parsed.replace(/\r\n?/g, '\n')
}

/** Serialize the replacement helper back to canonical Macrowhisper syntax. */
function serializeMacrowhisperReplacement(value: string): string {
  const normalized = value.replace(/\r\n?/g, '\n')
  let serialized = ''
  let index = 0
  while (index < normalized.length) {
    if (normalized[index] !== '\\') {
      serialized += normalized[index] === '\n' ? '\\n' : normalized[index]
      index += 1
      continue
    }

    const runStart = index
    while (index < normalized.length && normalized[index] === '\\') index += 1
    const slashCount = index - runStart
    if (index >= normalized.length) {
      serialized += '\\'.repeat(slashCount)
      continue
    }

    if (normalized[index] === '\n') {
      // Helper text doubles literal slashes before a Return; add the odd
      // newline marker when converting back to canonical wire syntax.
      serialized += '\\'.repeat(slashCount + 1) + 'n'
      index += 1
    } else if (normalized[index] === 'n') {
      // Even slash runs are already the canonical literal backslash+n form.
      // An odd run can only exist in programmatic state; normalize it to the
      // same visible escaped spelling rather than creating a newline token.
      serialized += '\\'.repeat(slashCount % 2 === 0 ? slashCount : slashCount + 1) + 'n'
      index += 1
    } else {
      serialized += '\\'.repeat(slashCount)
    }
  }
  return serialized
}

/**
 * Present an Insert action as editable text without expanding the syntax inside
 * complete placeholders. Ordinary text is semantic in this surface, so its
 * newline tokens become Returns. Placeholder arguments stay canonical and
 * inline so their delimiters and replacement stages remain legible.
 */
function presentMacrowhisperInsertPayload(value: string): string {
  let presented = ''
  let cursor = 0
  for (const segment of extractPlaceholderSegments(value)) {
    presented += parseMacrowhisperReplacement(value.slice(cursor, segment.start))
    presented += value.slice(segment.start, segment.end)
    cursor = segment.end
  }
  presented += parseMacrowhisperReplacement(value.slice(cursor))
  return presented
}

/**
 * Convert the Insert editor's hybrid presentation back to canonical v3 text.
 * Returns in ordinary text become `\n`. A Return typed inside a complete
 * placeholder is normalized only at this commit boundary, never under the
 * user's caret while they are composing the expression.
 */
function serializeMacrowhisperInsertPayload(value: string): string {
  let serialized = ''
  let cursor = 0
  for (const segment of extractPlaceholderSegments(value)) {
    serialized += serializeMacrowhisperReplacement(value.slice(cursor, segment.start))
    serialized += value.slice(segment.start, segment.end).replace(/\r\n?|\n/g, '\\n')
    cursor = segment.end
  }
  serialized += serializeMacrowhisperReplacement(value.slice(cursor))
  return serialized
}

function parsePlaceholderTail(value: string, allowFormat: boolean, requireTransformName = false): { format?: string; transformName?: string; regexReplacements: ReplacementStage[] } | null {
  let remaining = value
  let format: string | undefined
  if (remaining.startsWith(':') && !remaining.startsWith('::')) {
    if (!allowFormat) return null
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
    if (requireTransformName && !transformName) return null
    remaining = split.tail
  }

  const regexReplacements: ReplacementStage[] = []
  if (remaining.startsWith('||')) {
    const parts = splitByUnescapedDoublePipe(remaining.slice(2))
    if (parts.length % 2 !== 0) return null
    for (let index = 0; index < parts.length; index += 2) {
      regexReplacements.push({ find: parts[index], replace: parseMacrowhisperReplacement(parts[index + 1]) })
    }
    remaining = ''
  }
  if (remaining !== '') return null
  return { format, transformName, regexReplacements }
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

  // XML placeholders have a separate runtime grammar. The tag name is fixed
  // source data, while transforms and replacement stages use the same editor
  // controls as ordinary placeholders.
  if (/^(?:json|raw):xml:/i.test(remaining)) return null
  if (/^xml:/i.test(remaining)) {
    const xmlMatch = remaining.match(/^xml:([A-Za-z0-9_]+)(.*)$/)
    if (!xmlMatch) return null
    const tail = parsePlaceholderTail(xmlMatch[2], false, true)
    if (!tail) return null
    return {
      start: segment.start,
      end: segment.end,
      raw: value.slice(segment.start, segment.end),
      prefixType,
      key: 'xml',
      xmlTag: xmlMatch[1],
      transformName: tail.transformName,
      regexReplacements: tail.regexReplacements,
    }
  }

  let keyEnd = 0
  while (keyEnd < remaining.length && /[A-Za-z0-9_.]/.test(remaining[keyEnd])) keyEnd += 1
  if (keyEnd === 0) return null
  const key = remaining.slice(0, keyEnd)
  remaining = remaining.slice(keyEnd)

  const tail = parsePlaceholderTail(remaining, true)
  if (!tail) return null

  return {
    start: segment.start,
    end: segment.end,
    raw: value.slice(segment.start, segment.end),
    prefixType,
    key,
    format: tail.format,
    transformName: tail.transformName,
    regexReplacements: tail.regexReplacements,
  }
}

function placeholderLabel(placeholder: EditablePlaceholder | null): string {
  if (!placeholder) return 'Raw placeholder'
  if (placeholder.xmlTag !== undefined) return 'XML placeholder'
  if (placeholder.key === 'date') return 'Date'
  return placeholders.find((source) => source.key === placeholder.key)?.label ?? placeholder.key
}

function placeholderOccurrences(value: string): PlaceholderOccurrence[] {
  return extractPlaceholderSegments(value).map((segment, index) => {
    const placeholder = parseEditablePlaceholder(value, segment)
    const raw = value.slice(segment.start, segment.end)
    return {
      index,
      start: segment.start,
      end: segment.end,
      raw,
      label: placeholderLabel(placeholder),
      placeholder,
    }
  })
}

function rawRegexBody(raw: string): string {
  const trimmed = raw.trim()
  return isRawVoiceExpression(trimmed) ? trimmed.slice(2, -2) : raw
}

function pathKey(path: string[]): string {
  return path.join('\u001f')
}

function isFieldBlurActionTarget(target: EventTarget | null, key: string): boolean {
  return target instanceof HTMLElement && target.closest<HTMLButtonElement>('[data-field-blur-action]')?.dataset.fieldBlurAction === key
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

function shouldRestoreBuiltIn(field: string, value: FieldValue): boolean {
  if (field === 'clipboardIgnore' || field === 'bypassModes') return typeof value === 'string' && value !== ''
  if (field === 'history') return value !== null && value !== undefined && value !== ''
  const fixedNumericDefaults = new Set(['actionDelay', 'returnDelay', 'restoreClipboardDelay', 'scheduledActionTimeout', 'scriptWaitTimeout', 'clipboardBuffer'])
  if (!fixedNumericDefaults.has(field)) return false
  const defaultValue = schemaDefault(field)
  if (defaultValue === null || defaultValue === undefined) return false
  if (value === null || value === undefined || value === '') return false
  const currentValue = typeof value === 'string' ? Number(value) : value
  return Number.isNaN(currentValue) || !Object.is(currentValue, defaultValue)
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

function statusText(status: DraftStatus | undefined, previewMode = false): string {
  if (status === 'dirty') return 'Unsaved'
  if (status === 'saving') return previewMode ? 'Updating preview…' : 'Saving…'
  if (status === 'saved') return previewMode ? 'Updated in preview' : 'Saved'
  if (status === 'error') return previewMode ? 'Preview not updated' : 'Not saved'
  return ''
}

function isActionGroup(value: Screen): value is ActionGroup {
  return value !== 'defaults'
}

function isLegacySnapshot(snapshot: ConfigSnapshot): boolean {
  return snapshot.isLegacy === true || Boolean(snapshot.readOnly?.some((field) => field.path.length === 0))
}

function actionOptions(snapshot: ConfigSnapshot, currentPath?: string[]): SelectOption[] {
  const options: SelectOption[] = []
  const names = getAllActionNames(snapshot)
    .filter((item) => !(currentPath && item.group === currentPath[0] && item.name === currentPath[1]))
    .sort((a, b) => a.name.localeCompare(b.name))
  for (const item of names) {
    const action = (snapshot[item.group] as Record<string, InsertConfig>)[item.name]
    const name = actionDisplayName(item.name, action)
    const builtInLabel = action.action === '.autoPaste'
      ? 'Auto-paste'
      : action.action === '.none'
        ? 'Do nothing'
        : name
    const groupLabel = groupById.get(item.group)?.shortLabel ?? item.group
    const detail = name === item.name && action.action !== '.none'
      ? groupLabel
      : `${item.name} · ${groupLabel}`
    options.push({
      value: item.name,
      label: builtInLabel,
      detail,
      group: 'Actions',
      keywords: `${item.name} ${name} ${groupLabel}`,
    })
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

function EditorStatusControl({
  snapshot,
  pendingCount,
  hasSaveError,
  updateRequired,
  theme,
  onThemeChange,
  revealConfiguration,
}: {
  snapshot: ConfigSnapshot
  pendingCount: number
  hasSaveError: boolean
  updateRequired: boolean
  theme: ThemeChoice
  onThemeChange: (theme: ThemeChoice) => void
  revealConfiguration?: () => Promise<void>
}) {
  const previewMode = useContext(PreviewModeContext)
  const rootRef = useRef<HTMLDivElement>(null)
  const triggerRef = useRef<HTMLButtonElement>(null)
  const [open, setOpen] = useState(false)
  const [feedback, setFeedback] = useState('')
  const [feedbackError, setFeedbackError] = useState(false)
  const [feedbackContext, setFeedbackContext] = useState<'configuration' | 'diagnostics'>('configuration')
  const [revealing, setRevealing] = useState(false)

  const runtimeStatus = snapshot.runtime.status
  const status = updateRequired
    ? { label: 'Update required', tone: 'update-required' }
    : runtimeStatus === 'disconnected'
    ? { label: 'Disconnected', tone: 'disconnected' }
    : runtimeStatus === 'fallback'
      ? { label: 'Runtime fallback', tone: 'fallback' }
      : runtimeStatus === 'loading'
        ? { label: 'Connecting…', tone: 'loading' }
        : hasSaveError
          ? { label: previewMode ? 'Preview not updated' : 'Not saved', tone: 'disconnected' }
          : pendingCount > 0
            ? { label: previewMode ? 'Updating preview…' : pendingCount > 1 ? `Saving ${pendingCount}…` : 'Saving…', tone: 'saving' }
            : previewMode
              ? { label: 'Preview mode', tone: 'preview' }
              : { label: 'Connected', tone: 'connected' }
  const showStatusDetails = previewMode || updateRequired || runtimeStatus !== 'connected' || hasSaveError
  const showDiagnostics = runtimeStatus === 'disconnected' || runtimeStatus === 'fallback' || hasSaveError
  const statusMessage = updateRequired
    ? 'This v1/v2 configuration is running in compatibility mode. Update it to version 3 before editing.'
    : hasSaveError
    ? previewMode
      ? 'The latest change could not update the preview. Review the highlighted field and try again.'
      : 'The latest change could not be saved. Review the highlighted field and try again.'
    : previewMode && runtimeStatus === 'connected'
      ? 'Changes stay in this browser tab and reset when the preview reloads. macrowhisper.json is not changed.'
      : snapshot.runtime.message
  const configurationName = snapshot.path.split('/').filter(Boolean).pop() || 'Unavailable'

  useEffect(() => {
    if (!open) return
    const closeOnOutsidePointer = (event: PointerEvent) => {
      if (!rootRef.current?.contains(event.target as Node)) setOpen(false)
    }
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return
      event.preventDefault()
      setOpen(false)
      triggerRef.current?.focus()
    }
    document.addEventListener('pointerdown', closeOnOutsidePointer)
    document.addEventListener('keydown', closeOnEscape)
    return () => {
      document.removeEventListener('pointerdown', closeOnOutsidePointer)
      document.removeEventListener('keydown', closeOnEscape)
    }
  }, [open])

  const copyPath = async () => {
    setFeedback('')
    setFeedbackError(false)
    setFeedbackContext('configuration')
    try {
      if (!navigator.clipboard?.writeText) throw new Error('Clipboard access is unavailable.')
      await navigator.clipboard.writeText(snapshot.path)
      setFeedback('Configuration path copied.')
    } catch (error) {
      setFeedbackError(true)
      setFeedback(error instanceof Error ? error.message : 'The configuration path could not be copied.')
    }
  }

  const copyDiagnostics = async () => {
    setFeedback('')
    setFeedbackError(false)
    setFeedbackContext('diagnostics')
    const diagnostics = [
      'Macrowhisper editor diagnostics',
      `Status: ${status.label}`,
      `Message: ${statusMessage}`,
      `Configuration: ${snapshot.path || 'Unavailable'}`,
      `Schema: ${snapshot.schemaVersion > 0 ? snapshot.schemaVersion : 'Unavailable'}`,
      `Revision: ${snapshot.revision.version}`,
      `Generation: ${snapshot.revision.generation}`,
      `Fingerprint: ${snapshot.revision.fingerprint}`,
      `Disk: ${snapshot.disk.status}`,
    ].join('\n')
    try {
      if (!navigator.clipboard?.writeText) throw new Error('Clipboard access is unavailable.')
      await navigator.clipboard.writeText(diagnostics)
      setFeedback('Diagnostics copied.')
    } catch (error) {
      setFeedbackError(true)
      setFeedback(error instanceof Error ? error.message : 'Diagnostics could not be copied.')
    }
  }

  const reveal = async () => {
    if (!revealConfiguration || revealing) return
    setFeedback('')
    setFeedbackError(false)
    setFeedbackContext('configuration')
    setRevealing(true)
    try {
      await revealConfiguration()
      setFeedback('Configuration revealed in Finder.')
    } catch (error) {
      setFeedbackError(true)
      setFeedback(error instanceof Error ? error.message : 'The configuration could not be revealed in Finder.')
    } finally {
      setRevealing(false)
    }
  }

  return (
    <div ref={rootRef} className="editor-status-control">
      <button
        ref={triggerRef}
        type="button"
        className={`editor-status-trigger status-tone-${status.tone}`}
        aria-haspopup="dialog"
        aria-expanded={open}
        onClick={() => {
          setFeedback('')
          setFeedbackError(false)
          setFeedbackContext('configuration')
          setOpen((current) => !current)
        }}
      >
        <span className={`status-dot status-${status.tone}`} aria-hidden="true" />
        <span>{status.label}</span>
        <ChevronDownIcon aria-hidden="true" />
      </button>

      {open && (
        <div className="editor-details-popover" role="dialog" aria-label="Editor details">
          <div className="editor-details-heading">
            <strong>Editor</strong>
          </div>

          {showStatusDetails && (
            <div className="editor-details-status">
              <span className={`status-dot status-${status.tone}`} aria-hidden="true" />
              <div>
                <strong>{status.label}</strong>
                <span>{statusMessage}</span>
                {showDiagnostics && <button type="button" className="text-button editor-diagnostics-button" onClick={() => void copyDiagnostics()}>Copy diagnostics</button>}
                {feedback && feedbackContext === 'diagnostics' && <span className={feedbackError ? 'editor-details-feedback is-error' : 'editor-details-feedback'} role="status">{feedback}</span>}
              </div>
            </div>
          )}

          <div className="editor-details-section">
            <span className="editor-details-label">{previewMode ? 'Preview storage' : 'Configuration'}</span>
            <span className="editor-configuration-name" title={previewMode ? undefined : snapshot.path}>{previewMode ? 'In-memory sample data' : configurationName}</span>
            {previewMode ? (
              <span className="editor-details-feedback">Reloading resets these sample values. No configuration file is read or written.</span>
            ) : (
              <>
                <div className="editor-details-actions">
                  <button type="button" className="quiet-button compact" disabled={!revealConfiguration || revealing} title={revealConfiguration ? undefined : 'Available in the connected editor'} onClick={() => void reveal()}><FileTextIcon aria-hidden="true" /> {revealing ? 'Revealing…' : 'Reveal'}</button>
                  <button type="button" className="quiet-button compact" disabled={!snapshot.path} onClick={() => void copyPath()}><CopyIcon aria-hidden="true" /> Copy path</button>
                </div>
                {feedback && feedbackContext === 'configuration' && <span className={feedbackError ? 'editor-details-feedback is-error' : 'editor-details-feedback'} role="status">{feedback}</span>}
              </>
            )}
          </div>

          <div className="editor-details-section">
            <span className="editor-details-label">Appearance</span>
            <ThemeControl theme={theme} onChange={onThemeChange} />
          </div>
        </div>
      )}
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
  const previewMode = useContext(PreviewModeContext)
  if (!entry) return null
  const canResync = entry.status === 'error' && (entry.errorCode === 'conflict' || entry.errorCode === 'stale')
  return (
    <div className="field-state-wrap">
      <span className={`field-state field-state-${entry.status}`} aria-live="polite">
        {entry.status === 'saved' && <CheckIcon aria-hidden="true" />}
        {entry.status === 'error' && <ExclamationTriangleIcon aria-hidden="true" />}
        {statusText(entry.status, previewMode)}
      </span>
      {(entry.status === 'dirty' || entry.status === 'error') && (
        <button type="button" className="text-button" data-field-blur-action={pathKey(entry.path)} onPointerDown={(event) => event.preventDefault()} onClick={onRevert}>Revert</button>
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
  const chooseDirectory = store.chooseDirectory
    ? (purpose: FolderPickerPurpose) => store.chooseDirectory!(purpose)
    : undefined
  const revealConfiguration = store.revealConfiguration
    ? () => store.revealConfiguration!()
    : undefined
  const updateConfiguration = store.updateConfiguration
    ? () => store.updateConfiguration!()
    : undefined
  const [snapshot, setSnapshot] = useState<ConfigSnapshot>(() => store.getSnapshot())
  const [screen, setScreen] = useState<Screen>('defaults')
  const [railGroup, setRailGroup] = useState<ActionGroup | null>(null)
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
  const [migrationStatus, setMigrationStatus] = useState<'idle' | 'updating' | 'updated' | 'error'>('idle')
  const [migrationError, setMigrationError] = useState('')
  const [deleteOpen, setDeleteOpen] = useState(false)
  const [renameValue, setRenameValue] = useState('')
  const [payloadRecovery, setPayloadRecovery] = useState<Record<string, string>>({})
  const [navPrompt, setNavPrompt] = useState<NavigationPrompt | null>(null)
  const [mobileNavOpen, setMobileNavOpen] = useState(false)
  const [isNarrow, setIsNarrow] = useState(() => typeof window !== 'undefined' && window.matchMedia?.('(max-width: 780px)').matches)
  const [pendingCount, setPendingCount] = useState(0)
  const snapshotRef = useRef(snapshot)
  const draftsRef = useRef(drafts)
  const mutationQueueRef = useRef<Promise<boolean>>(Promise.resolve(true))
  const pendingMutationsRef = useRef(new Map<string, Promise<boolean>>())
  const savedTimersRef = useRef(new Map<string, ReturnType<typeof setTimeout>>())
  const mountedRef = useRef(true)
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
      const firstControl = sidebarRef.current?.querySelector<HTMLElement>('button, a, input, select, textarea, summary')
      firstControl?.focus()
      const closeOnEscape = (event: KeyboardEvent) => {
        if (event.key === 'Escape') {
          event.preventDefault()
          setMobileNavOpen(false)
          return
        }
        if (event.key !== 'Tab') return
        const controls = Array.from(sidebarRef.current?.querySelectorAll<HTMLElement>('button:not([disabled]), a[href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), summary') ?? [])
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
    }
    const currentScenario = fixtureStore?.getScenario?.()
    if (currentScenario && scenario !== currentScenario) setScenario(currentScenario)
  }, [screen, selectedName, snapshot, scenario, fixtureStore])

  const currentGroup = isActionGroup(screen) ? groupById.get(screen) : undefined
  const currentAction = isActionGroup(screen) && selectedName ? snapshot[screen][selectedName] : undefined
  const browsedGroup = railGroup ? groupById.get(railGroup) : undefined
  const updateRequired = isLegacySnapshot(snapshot)

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

  const scheduleSavedExpiry = useCallback((key: string, version: number, savedAt: number) => {
    if (!mountedRef.current) return
    const previousTimer = savedTimersRef.current.get(key)
    if (previousTimer) clearTimeout(previousTimer)
    const timer = setTimeout(() => {
      if (!mountedRef.current) return
      updateDrafts((previous) => {
        const entry = previous[key]
        if (entry?.status !== 'saved' || entry.version !== version || entry.savedAt !== savedAt) return previous
        const next = { ...previous }
        delete next[key]
        return next
      })
      savedTimersRef.current.delete(key)
    }, 1800)
    savedTimersRef.current.set(key, timer)
  }, [updateDrafts])

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
      for (const timer of savedTimersRef.current.values()) clearTimeout(timer)
      savedTimersRef.current.clear()
    }
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
          version: (preserveBaseline ? existing.version : (existing?.version ?? 0)) + 1,
          savedAt: undefined,
        },
      }
    })
  }, [updateDrafts])

  const commitField = useCallback(async (path: string[], rawValue: FieldValue): Promise<boolean> => {
    if (isLegacySnapshot(snapshotRef.current)) return false
    const key = pathKey(path)
    let value = rawValue
    const field = path[path.length - 1]
    const numericField = field === 'actionDelay' || field === 'returnDelay' || field === 'restoreClipboardDelay' || field === 'scheduledActionTimeout' || field === 'scriptWaitTimeout' || field === 'clipboardBuffer' || field === 'history'
    if (numericField) {
      if (typeof rawValue === 'string' && rawValue.trim() !== '') value = Number(rawValue)
      else if (typeof rawValue === 'string' && rawValue.trim() === '' && path[0] === 'defaults') value = null
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
          version: (preserveBaseline ? existing?.version ?? 0 : (existing?.version ?? 0) + 1),
          requestId,
          savedAt: undefined,
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
          const savedAt = Date.now()
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
            version: existing.version + 1,
            savedAt,
          }
          return next
        })
        const savedEntry = draftsRef.current[key]
        if (savedEntry?.status === 'saved' && savedEntry.savedAt !== undefined) {
          scheduleSavedExpiry(key, savedEntry.version, savedEntry.savedAt)
        }
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
      if (isFieldBlurActionTarget(event.relatedTarget, pathKey(path))) return
      const entry = draftsRef.current[pathKey(path)]
      if (entry?.status === 'dirty' || event.currentTarget.value !== displayValue(readPath(snapshotRef.current, path))) void commitField(path, event.currentTarget.value)
    },
    onKeyDown: (event: ReactKeyboardEvent<HTMLInputElement | HTMLTextAreaElement>) => {
      if (event.key !== 'Enter' || event.currentTarget instanceof HTMLTextAreaElement) return
      event.preventDefault()
      event.currentTarget.blur()
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
    setPayloadRecovery({})
    setScreen('defaults')
    setRailGroup(null)
    setSelectedName(next === 'empty' ? '' : 'dailyNotes')
    setMobileNavOpen(false)
  }, [fixtureStore])

  const reconnectFixture = () => {
    fixtureStore?.reconnect()
  }

  const runConfigurationUpdate = async () => {
    if (!updateConfiguration || migrationStatus === 'updating') return false
    setMigrationStatus('updating')
    setMigrationError('')
    try {
      const next = await updateConfiguration()
      snapshotRef.current = next
      setSnapshot(next)
      if (isLegacySnapshot(next)) {
        throw new Error('The configuration still requires migration. Try the update again or run macrowhisper --update-config.')
      }
      draftsRef.current = {}
      setDrafts({})
      setMigrationStatus('updated')
      return true
    } catch (error) {
      setMigrationStatus('error')
      setMigrationError(error instanceof Error ? error.message : 'The configuration could not be updated to version 3.')
      return false
    }
  }

  const navigate = useCallback((target: NavigationPrompt) => {
    if (target.scenario) {
      applyScenario(target.scenario)
      return
    }
    setScreen(target.screen)
    if (isActionGroup(target.screen)) {
      const nextName = target.name ?? ''
      setSelectedName(nextName)
      if (target.screen === 'inserts') setRenameValue(nextName)
      setRailGroup(target.screen)
    } else {
      setRailGroup(null)
    }
    setMobileNavOpen(false)
  }, [applyScenario])

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
    if (!target.scenario && target.screen === screen && (target.name ?? '') === (isActionGroup(screen) ? selectedName : '')) return
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
  const browseGroup = (group: GroupDefinition) => {
    setRailGroup(group.id)
    setSearch('')
  }

  const showSectionNavigation = () => {
    setRailGroup(null)
    setSearch('')
  }

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
    if (isLegacySnapshot(snapshotRef.current)) return
    setRailGroup('inserts')
    if (isNarrow) setMobileNavOpen(true)
    setCreateOpen(true)
    setDuplicateOpen(false)
    setCreateName('')
    setCreatePayload('{{swResult}}')
    setLifecycleError('')
  }

  const createInsert = async (duplicate: boolean) => {
    if (isLegacySnapshot(snapshotRef.current)) return false
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
        setRailGroup('inserts')
        setSelectedName(createdName)
        setRenameValue(createdName)
        setMobileNavOpen(false)
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
    if (isLegacySnapshot(snapshotRef.current)) return false
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
        setPayloadRecovery((current) => {
          if (!(selectedName in current)) return current
          const retained = current[selectedName]
          const next = { ...current }
          delete next[selectedName]
          next[clean] = retained
          return next
        })
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
    if (isLegacySnapshot(snapshotRef.current)) return false
    if (lifecycleStatus === 'saving' || lifecyclePromiseRef.current) return false
    setLifecycleError('')
    setLifecycleStatus('saving')
    const operation = (async () => {
      try {
        const result = await store.deleteInsert(selectedName)
        snapshotRef.current = result.snapshot
        setSnapshot(result.snapshot)
        setPayloadRecovery((current) => {
          if (!(selectedName in current)) return current
          const next = { ...current }
          delete next[selectedName]
          return next
        })
        const next = Object.keys(result.snapshot.inserts)[0] ?? ''
        setDeleteOpen(false)
        setSelectedName(next)
        setRenameValue(next)
        setRailGroup('inserts')
        setLifecycleStatus('saved')
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
  const hasSaveError = Object.values(drafts).some((entry) => entry.status === 'error') || Boolean(lifecycleError)

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
    <PreviewModeContext.Provider value={Boolean(fixtureStore)}>
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

        {browsedGroup ? (
          <ActionList
            group={browsedGroup}
            snapshot={snapshot}
            selectedName={screen === browsedGroup.id ? selectedName : ''}
            search={search}
            setSearch={setSearch}
            onBack={showSectionNavigation}
            onSelect={(name) => void handleSelectAction(browsedGroup.id, name)}
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
            readOnly={updateRequired}
          />
        ) : (
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
                  onClick={() => browseGroup(group)}
                >
                  {group.icon}<span>{group.label}</span><span className="nav-count">{count}</span>
                </button>
              )
            })}
          </nav>
        )}

        <div className="sidebar-bottom">
          <EditorStatusControl snapshot={snapshot} pendingCount={pendingCount} hasSaveError={hasSaveError} updateRequired={updateRequired} theme={theme} onThemeChange={setTheme} revealConfiguration={revealConfiguration} />
          {fixtureStore && snapshot.runtime.status === 'disconnected' && <button type="button" className="quiet-button compact connection-action" onClick={reconnectFixture}>Reconnect fixture</button>}
        </div>
      </aside>

      <main className="main-panel">
        <header className="topbar">
          <button ref={mobileMenuRef} type="button" className="mobile-menu-button" aria-expanded={mobileNavOpen} aria-controls="configuration-navigation" onClick={() => setMobileNavOpen(true)}><GearIcon aria-hidden="true" /> Menu</button>
          <div className="breadcrumb"><span>Macrowhisper</span><span className="breadcrumb-separator">/</span><span>{screen === 'defaults' ? 'Defaults' : currentGroup?.label}</span>{currentAction && <><span className="breadcrumb-separator">/</span><strong title={selectedName}>{selectedName}</strong></>}</div>
          <div className="topbar-tools">
            {fixtureStore && <label className="scenario-picker">Preview
              <select aria-label="Preview scenario" value={scenario} onChange={(event) => handleScenario(event.target.value as StoreScenario)}>
                <option value="populated">Populated</option><option value="invalid">Invalid field</option><option value="conflict">Conflict</option><option value="empty">Empty Inserts</option><option value="disconnected">Disconnected</option>
              </select>
              <ChevronDownIcon aria-hidden="true" />
            </label>}
          </div>
        </header>

        {fixtureStore && <div className="prototype-notice" role="note"><span className="status-dot status-preview" aria-hidden="true" /><div><strong>Preview mode</strong><span>Changes are temporary in this browser tab. They do not write macrowhisper.json, and reloading resets them.</span></div></div>}

        {updateRequired && <LegacyMigrationBanner snapshot={snapshot} status={migrationStatus} error={migrationError} canUpdate={Boolean(updateConfiguration)} onUpdate={() => void runConfigurationUpdate()} />}
        {snapshot.disk.status !== 'valid' && <DiskBanner snapshot={snapshot} />}
        {snapshot.runtime.status === 'disconnected' && <div className="inline-banner warning"><ExclamationTriangleIcon aria-hidden="true" /><div><strong>Working offline</strong><span>{fixtureStore ? 'Drafts stay in this tab until the fixture adapter reconnects. Retry after choosing a connected scenario.' : 'Open a fresh editor link with macrowhisper --editor to reconnect. Unsaved drafts remain in this tab.'}</span></div></div>}

        <fieldset disabled={updateRequired} className="workspace-editing-disabled" aria-label={updateRequired ? 'Configuration editing disabled until migration' : undefined}>
          {screen === 'defaults' ? (
            <DefaultsScreen snapshot={snapshot} valueFor={valueFor} drafts={drafts} textHandlers={textHandlers} setDraftValue={setDraftValue} commitField={commitField} revertField={revertField} retryField={retryField} resyncField={resyncField} folderPickerPreview={Boolean(fixtureStore)} chooseDirectory={chooseDirectory} />
          ) : screen === 'inserts' ? (
            currentAction ? (
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
                onRename={renameInsert}
                onDuplicate={() => { setRailGroup('inserts'); setDuplicateOpen(true); setCreateOpen(false); setCreateName(`${selectedName} copy`); setLifecycleError(''); if (isNarrow) setMobileNavOpen(true) }}
                onDelete={() => setDeleteOpen(true)}
                onBack={() => { setRailGroup('inserts'); setMobileNavOpen(true) }}
                lifecycleError={lifecycleError}
                lifecycleStatus={lifecycleStatus}
                editingBlocked={updateRequired}
                recoveredPayload={payloadRecovery[selectedName]}
                onRetainPayload={(text) => setPayloadRecovery((current) => ({ ...current, [selectedName]: text }))}
                onClearRetainedPayload={() => setPayloadRecovery((current) => {
                  if (!(selectedName in current)) return current
                  const next = { ...current }
                  delete next[selectedName]
                  return next
                })}
                folderPickerPreview={Boolean(fixtureStore)}
                chooseDirectory={chooseDirectory}
              />
            ) : (
              <EmptyState onCreate={openCreate} />
            )
          ) : (
            <UnsupportedActionGroup group={currentGroup!} selectedName={selectedName} snapshot={snapshot} fixtureBacked={Boolean(fixtureStore)} />
          )}
        </fieldset>
      </main>

      {isNarrow && mobileNavOpen && <button type="button" className="mobile-nav-backdrop" tabIndex={-1} aria-label="Close navigation" onClick={() => setMobileNavOpen(false)} />}

      {deleteOpen && <DeleteDialog name={actionDisplayName(selectedName, currentAction)} storedName={selectedName} fixtureBacked={Boolean(fixtureStore)} references={inboundReferences(snapshot, selectedName)} onClose={() => setDeleteOpen(false)} onDelete={() => void deleteInsert()} busy={lifecycleStatus === 'saving'} />}
      {navPrompt && <NavigationDialog target={navPrompt.label} onClose={() => setNavPrompt(null)} onDiscard={discardAndNavigate} />}
    </div>
    </PreviewModeContext.Provider>
  )
}

function LegacyMigrationBanner({ snapshot, status, error, canUpdate, onUpdate }: { snapshot: ConfigSnapshot; status: 'idle' | 'updating' | 'updated' | 'error'; error: string; canUpdate: boolean; onUpdate: () => void }) {
  const [copyFeedback, setCopyFeedback] = useState('')
  const command = 'macrowhisper --update-config'
  const copyCommand = async () => {
    try {
      if (!navigator.clipboard?.writeText) throw new Error('Clipboard access is unavailable.')
      await navigator.clipboard.writeText(command)
      setCopyFeedback('Update command copied.')
    } catch (copyError) {
      setCopyFeedback(copyError instanceof Error ? copyError.message : 'The update command could not be copied.')
    }
  }
  const updating = status === 'updating'
  return <section className="inline-banner legacy-migration-banner" role="alert" aria-labelledby="legacy-migration-title" aria-describedby="legacy-migration-description">
    <ExclamationTriangleIcon aria-hidden="true" />
    <div className="legacy-migration-copy">
      <h2 id="legacy-migration-title">Update required before editing</h2>
      <p id="legacy-migration-description">This v1/v2 configuration is running in compatibility mode, so the editor is read-only. Update it to version 3 to use the workspace. Macrowhisper creates a backup beside <code>{snapshot.path.split('/').filter(Boolean).pop() || 'your configuration file'}</code> before migrating, and this explicit update does not change the automatic update setting.</p>
      {error && <span className="legacy-migration-error" role="status">{error}</span>}
      <div className="legacy-migration-actions">
        <button type="button" className="primary-button compact" onClick={onUpdate} disabled={!canUpdate || updating}>{updating ? 'Updating to version 3…' : 'Update to version 3'}</button>
        <button type="button" className="quiet-button compact" onClick={() => void copyCommand()} disabled={updating}><CopyIcon aria-hidden="true" /> Copy update command</button>
      </div>
      {status === 'error' && <span className="legacy-migration-help">You can also run <code>{command}</code> in Terminal, then return here to refresh.</span>}
      {copyFeedback && <span className="legacy-migration-feedback" role="status">{copyFeedback}</span>}
    </div>
  </section>
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
  folderPickerPreview: boolean
  chooseDirectory?: (purpose: FolderPickerPurpose) => Promise<string | null>
}

function DefaultsScreen({ snapshot, valueFor, drafts, textHandlers, setDraftValue, commitField, revertField, retryField, resyncField, folderPickerPreview, chooseDirectory }: DefaultsScreenProps) {
  const [openSection, setOpenSection] = useState<string | null>(() => {
    try {
      const stored = localStorage.getItem(DEFAULTS_OPEN_SECTION_STORAGE_KEY)
      if (!stored || stored === 'null') return null
      return defaultFieldGroups.some((section) => section.key === stored) ? stored : null
    } catch {
      return null
    }
  })
  useEffect(() => {
    try {
      localStorage.setItem(DEFAULTS_OPEN_SECTION_STORAGE_KEY, openSection ?? '')
    } catch {
      // Accordion state is a convenience and should not block configuration.
    }
  }, [openSection])
  const sectionProps = (section: { key: string; label: string; description: string; fields: string[] }) => ({
    section,
    open: openSection === section.key,
    onToggle: (nextOpen: boolean) => setOpenSection((current) => {
      if (nextOpen) return section.key
      return current === section.key ? null : current
    }),
  })
  return (
    <div className="screen-content defaults-screen">
      <div className="screen-intro">
        <div><h1>Defaults</h1><p className="screen-description">Set the behavior shared by every action. Built-in marks what Macrowhisper ships with; Use built-in removes a custom value.</p></div>
      </div>
      <div className="defaults-accordion">
        {defaultFieldGroups.map((section) => <DefaultSection key={section.key} {...sectionProps(section)} snapshot={snapshot} valueFor={valueFor} drafts={drafts} textHandlers={textHandlers} setDraftValue={setDraftValue} commitField={commitField} revertField={revertField} retryField={retryField} resyncField={resyncField} folderPickerPreview={folderPickerPreview} chooseDirectory={chooseDirectory} />)}
      </div>
    </div>
  )
}

interface DefaultSectionProps extends DefaultsScreenProps {
  section: { key: string; label: string; description: string; fields: string[] }
  open: boolean
  onToggle: (open: boolean) => void
}

function DefaultSection({ section, open, onToggle, snapshot, valueFor, drafts, textHandlers, setDraftValue, commitField, revertField, retryField, resyncField, folderPickerPreview, chooseDirectory }: DefaultSectionProps) {
  const summary = defaultSectionSummary(section.key, snapshot, valueFor)
  const layout = defaultFieldLayouts[section.key]
  const renderField = (field: string) => <DefaultField key={field} field={field} snapshot={snapshot} valueFor={valueFor} drafts={drafts} textHandlers={textHandlers} setDraftValue={setDraftValue} commitField={commitField} revertField={revertField} retryField={retryField} resyncField={resyncField} folderPickerPreview={folderPickerPreview} chooseDirectory={chooseDirectory} />
  return (
    <section className="settings-section">
      <Disclosure title={section.label} subtitle="" meta={summary} open={open} onToggle={onToggle} variant="defaults">
        <p className="defaults-section-description">{section.description}</p>
        <div className={layout ? 'field-list default-field-groups' : 'field-list'}>
          {layout ? layout.map((group) => {
            const headingId = `defaults-${section.key}-${group.key}`
            return <div className="default-field-group" role="group" aria-labelledby={headingId} key={group.key}><div className="default-field-group-heading"><h3 id={headingId}>{group.label}</h3><p>{group.description}</p></div><div className="default-field-group-fields">{group.fields.map(renderField)}</div></div>
          }) : section.fields.map(renderField)}
        </div>
      </Disclosure>
    </section>
  )
}

function FolderIcon() {
  return <svg viewBox="0 0 15 15" aria-hidden="true"><path fill="currentColor" d="M1.5 2.5A1.5 1.5 0 0 1 3 1h2.1c.4 0 .8.16 1.08.44L7.74 3H12a1.5 1.5 0 0 1 1.5 1.5v6A1.5 1.5 0 0 1 12 12H3a1.5 1.5 0 0 1-1.5-1.5v-8Zm1 1.5v6.5c0 .28.22.5.5.5h9a.5.5 0 0 0 .5-.5v-6a.5.5 0 0 0-.5-.5H7.53c-.4 0-.78-.16-1.06-.44L4.9 2H3a.5.5 0 0 0-.5.5V4Z" /></svg>
}

function FolderPathControl({ label, blurActionKey, children, chooseFolder, onSelected }: { label: string; blurActionKey?: string; children: ReactNode; chooseFolder?: () => Promise<string | null>; onSelected?: (path: string) => void }) {
  const [previewOpen, setPreviewOpen] = useState(false)
  const [choosing, setChoosing] = useState(false)
  const [pickerError, setPickerError] = useState('')
  const errorId = `folder-picker-${label.replace(/[^a-z0-9]+/gi, '-').toLowerCase()}-error`
  const choose = async () => {
    if (!chooseFolder) {
      setPreviewOpen(true)
      return
    }
    setChoosing(true)
    setPickerError('')
    try {
      const path = await chooseFolder()
      if (path) onSelected?.(path)
    } catch (error) {
      setPickerError(error instanceof Error ? error.message : 'The folder picker could not be opened. Try again, or type the path.')
    } finally {
      setChoosing(false)
    }
  }
  return <>
    <div className="path-control">
      {children}
      <button type="button" className="quiet-button path-choose-button" aria-label={`Choose ${label}`} aria-haspopup={chooseFolder ? undefined : 'dialog'} aria-expanded={chooseFolder ? undefined : previewOpen} aria-describedby={pickerError ? errorId : undefined} disabled={choosing} data-field-blur-action={blurActionKey} onClick={() => void choose()}><FolderIcon /> {choosing ? 'Choosing…' : 'Choose…'}</button>
    </div>
    {pickerError && <p id={errorId} className="path-picker-error" role="alert">{pickerError}</p>}
    {previewOpen && <FolderChooserPreviewDialog label={label} onClose={() => setPreviewOpen(false)} />}
  </>
}

function NullableTextControl({
  kind,
  controlId,
  value,
  onChoice,
  onText,
  onBlur,
  ariaLabel,
  errorId,
  revertKey,
  collapseDefault = false,
  pending = false,
  folderPickerPreview = false,
  chooseDirectory,
}: {
  kind: 'icon' | 'moveTo'
  controlId: string
  value: FieldValue
  onChoice: (value: FieldValue) => void
  onText: (value: string) => void
  onBlur: (value: string) => void
  ariaLabel: string
  errorId?: string
  revertKey?: string
  collapseDefault?: boolean
  pending?: boolean
  folderPickerPreview?: boolean
  chooseDirectory?: (purpose: FolderPickerPurpose) => Promise<string | null>
}) {
  const isMove = kind === 'moveTo'
  const isCustomValue = typeof value === 'string' && value !== '' && (!isMove || value !== '.delete')
  const [customOpen, setCustomOpen] = useState(isCustomValue)
  const mode = customOpen || isCustomValue ? 'custom' : isMove && value === '.delete' ? 'delete' : collapseDefault ? 'empty' : pending ? 'pending' : 'empty'
  const inputId = `${controlId}-custom-value`
  const builtInActive = collapseDefault && mode === 'empty'
  const builtInDescriptionId = `${kind}-built-in-description`
  return (
    <div className={`nullable-control nullable-control-${kind}`}>
      <div className="select-control-wrapper nullable-select-control">
        <select id={controlId} aria-label={`${ariaLabel} mode`} aria-describedby={builtInActive ? builtInDescriptionId : undefined} value={mode} onChange={(event) => {
          const next = event.target.value
          if (next === 'empty') {
            setCustomOpen(false)
            onChoice('')
          } else if (next === 'delete') {
            setCustomOpen(false)
            onChoice('.delete')
          } else {
            setCustomOpen(true)
          }
        }}>
          {collapseDefault ? <>
            <optgroup label="Built-in value"><option value="empty">{isMove ? 'Keep recording' : 'No icon'}</option></optgroup>
            <hr />
            <optgroup label="Explicit values">{isMove && <option value="delete">Delete recording</option>}<option value="custom">Custom</option></optgroup>
          </> : <>
            {pending && <option value="pending" disabled>Choose value…</option>}
            <option value="empty">{isMove ? 'Keep recording' : 'No icon'}</option>
            {isMove && <option value="delete">Delete recording</option>}
            <option value="custom">Custom</option>
          </>}
        </select>
        {builtInActive && <BuiltInPill id={builtInDescriptionId} />}
      </div>
      {mode === 'custom' && (isMove && (folderPickerPreview || chooseDirectory) ? <FolderPathControl label="recording destination" blurActionKey={revertKey} chooseFolder={chooseDirectory ? () => chooseDirectory('moveTo') : undefined} onSelected={(path) => onChoice(path)}><input
        id={inputId}
        value={displayValue(value) === '.delete' ? '' : displayValue(value)}
        onChange={(event) => onText(event.target.value)}
        onBlur={(event) => { if (!revertKey || !isFieldBlurActionTarget(event.relatedTarget, revertKey)) onBlur(event.target.value) }}
        aria-label="Recording folder path"
        aria-describedby={errorId}
        placeholder="~/Documents/processed-recordings"
      /></FolderPathControl> : <input
        id={inputId}
        value={displayValue(value) === '.delete' ? '' : displayValue(value)}
        onChange={(event) => onText(event.target.value)}
        onBlur={(event) => { if (!revertKey || !isFieldBlurActionTarget(event.relatedTarget, revertKey)) onBlur(event.target.value) }}
        aria-label={isMove ? 'Recording folder path' : 'Custom icon'}
        aria-describedby={errorId}
        placeholder={isMove ? '~/Documents/processed-recordings' : 'Optional symbol'}
      />)}
    </div>
  )
}

function DefaultField({ field, snapshot, valueFor, drafts, textHandlers, setDraftValue, commitField, revertField, retryField, resyncField, folderPickerPreview, chooseDirectory }: { field: string } & DefaultsScreenProps) {
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
    const actionChoices = options
    const builtInChoiceValue = field === 'activeAction' ? displayValue(schemaDefault('activeAction')) : EMPTY_CHOICE
    const builtInChoices = actionChoices.filter((option) => option.value === builtInChoiceValue)
    const configuredChoices = actionChoices.filter((option) => option.value !== builtInChoiceValue)
    const selectedOption = actionChoices.find((option) => option.value === rootReferenceValue)
    const builtInActive = field === 'nextAction' ? rootReferenceValue === EMPTY_CHOICE : selectedOption?.value === builtInChoiceValue
    const builtInDescriptionId = `${field}-built-in-description`
    const descriptionIds = [entry?.error ? fieldErrorId(path) : '', builtInActive ? builtInDescriptionId : ''].filter(Boolean).join(' ') || undefined
    const pickerOptions: ActionPickerOption[] = [
      ...(field === 'nextAction'
        ? [{ value: EMPTY_CHOICE, label: emptyChoiceLabel, detail: 'Built-in', group: 'Built-in value', keywords: 'none stop chain' }]
        : builtInChoices.map((option) => ({ ...option, group: 'Built-in value' }))),
      ...(field === 'activeAction' ? [{ value: EMPTY_CHOICE, label: emptyChoiceLabel, detail: 'Do nothing when no trigger matches', group: 'Actions', keywords: 'none' }] : []),
      ...configuredChoices.map((option) => ({ ...option, group: 'Actions' })),
    ]
    return <SettingRow label={meta.label} description={meta.description} state={<FieldState entry={entry} {...saveProps} />} controlId={field}><div className="select-control-wrapper select-metadata-stack"><ActionPicker id={field} label={meta.label} describedBy={descriptionIds} value={rootReferenceValue} options={pickerOptions} onChange={(selectedValue) => {
      const next = selectedValue === EMPTY_CHOICE ? '' : selectedValue
      onChoice(next)
    }} />{builtInActive && <BuiltInPill id={builtInDescriptionId} />}</div></SettingRow>
  }

  if (field === 'icon' || field === 'moveTo') {
    return <SettingRow label={meta.label} description={meta.description} state={<FieldState entry={entry} {...saveProps} />} controlId={field}><NullableTextControl kind={field} controlId={field} value={value} onChoice={onChoice} onText={(next) => setDraftValue(path, next)} onBlur={(next) => { if (entry?.status === 'dirty' || next !== displayValue(readPath(snapshot, path))) void commitField(path, next) }} ariaLabel={meta.label} errorId={fieldErrorId(path)} revertKey={pathKey(path)} collapseDefault folderPickerPreview={folderPickerPreview} chooseDirectory={chooseDirectory} /></SettingRow>
  }

  if (field === 'watch' || field === 'clipboardIgnore' || field === 'bypassModes') {
    const props = textHandlers(path)
    const useBuiltIn = shouldRestoreBuiltIn(field, value) ? <button type="button" className="text-button" data-field-blur-action={pathKey(path)} onPointerDown={(event) => event.preventDefault()} onClick={() => onChoice(null)}>Use built-in</button> : null
    const descriptionIds = [`${field}-description`, entry?.error ? fieldErrorId(path) : ''].filter(Boolean).join(' ')
    const placeholder = field === 'watch' ? '~/superwhisper' : field === 'clipboardIgnore' ? 'Arc|Bitwarden|com.apple.passwords' : 'dictation|raw'
    const input = <input id={field} {...props} aria-label={meta.label} aria-describedby={descriptionIds} placeholder={placeholder} />
    return <SettingRow label={meta.label} description={meta.description} state={<FieldState entry={entry} {...saveProps} />} utility={useBuiltIn} controlId={field}><div className="setting-input-stack">{field === 'watch' && (folderPickerPreview || chooseDirectory) ? <FolderPathControl label="Superwhisper folder" blurActionKey={pathKey(path)} chooseFolder={chooseDirectory ? () => chooseDirectory('watch') : undefined} onSelected={(selectedPath) => void commitField(path, selectedPath)}>{input}</FolderPathControl> : input}</div></SettingRow>
  }

  if (field === 'history' || field === 'actionDelay' || field === 'returnDelay' || field === 'restoreClipboardDelay' || field === 'scheduledActionTimeout' || field === 'scriptWaitTimeout' || field === 'clipboardBuffer') {
    const props = textHandlers(path)
    const useBuiltIn = shouldRestoreBuiltIn(field, value) ? <button type="button" className="text-button" data-field-blur-action={pathKey(path)} onPointerDown={(event) => event.preventDefault()} onClick={() => onChoice(null)}>Use built-in</button> : null
    return <SettingRow label={meta.label} description={meta.description} state={<FieldState entry={entry} {...saveProps} />} utility={useBuiltIn} controlId={field}><div className="setting-input-stack"><div className="input-with-unit"><input id={field} {...props} aria-label={meta.label} aria-describedby={entry?.error ? fieldErrorId(path) : undefined} inputMode="decimal" type="text" placeholder={field === 'history' ? 'Keep forever' : numberDefaultText(field)} /><span>{numberUnits[field]}</span></div></div></SettingRow>
  }

  if (booleanFields.has(field)) {
    const builtIn = schemaDefault(field) === true
    const selected = value === null || value === undefined ? (builtIn ? 'on' : 'off') : value ? 'on' : 'off'
    const builtInValue = builtIn ? 'on' : 'off'
    const alternativeValue = builtIn ? 'off' : 'on'
    const builtInActive = selected === builtInValue
    const builtInDescriptionId = `${field}-built-in-description`
    const descriptionIds = [entry?.error ? fieldErrorId(path) : '', builtInActive ? builtInDescriptionId : ''].filter(Boolean).join(' ') || undefined
    return <SettingRow label={meta.label} description={meta.description} state={<FieldState entry={entry} {...saveProps} />} controlId={field}><div className="select-control-wrapper select-metadata-stack"><select id={field} aria-describedby={descriptionIds} aria-label={meta.label} value={selected} onChange={(event) => onChoice(event.target.value === 'on')}><optgroup label="Built-in value"><option value={builtInValue}>{booleanText(field, builtIn)}</option></optgroup><hr /><optgroup label="Explicit values"><option value={alternativeValue}>{booleanText(field, !builtIn)}</option></optgroup></select>{builtInActive && <BuiltInPill id={builtInDescriptionId} />}</div></SettingRow>
  }

  return null
}

function SettingRow({ label, description, state, utility, children, controlId }: { label: string; description: string; state?: ReactNode; utility?: ReactNode; children: ReactNode; controlId?: string }) {
  return <div className="setting-row"><div className="setting-copy"><div className="setting-label"><label htmlFor={controlId}>{label}</label><div className="setting-utility"><div className="setting-utility-state">{state}</div><div className="setting-utility-action">{utility}</div></div></div><p id={controlId ? `${controlId}-description` : undefined}>{description}</p></div><div className="setting-control">{children}</div></div>
}

function BuiltInPill({ id }: { id: string }) {
  return <span id={id} className="built-in-pill">Built-in</span>
}

interface ActionListProps {
  group: GroupDefinition
  snapshot: ConfigSnapshot
  selectedName: string
  search: string
  setSearch: (value: string) => void
  onBack: () => void
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
  readOnly?: boolean
}

function ActionList({ group, snapshot, selectedName, search, setSearch, onBack, onSelect, onCreate, createOpen, duplicateOpen, createName, createPayload, setCreateName, setCreatePayload, onSubmitCreate, onCancelCreate, lifecycleError, lifecycleStatus, readOnly = false }: ActionListProps) {
  const actions = snapshot[group.id]
  const names = Object.keys(actions).filter((name) => name.toLocaleLowerCase().includes(search.toLocaleLowerCase()))
  const supportsLifecycle = group.id === 'inserts'
  const onListKeyDown = (event: ReactKeyboardEvent<HTMLDivElement>) => {
    if (!['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) return
    const options = Array.from(event.currentTarget.querySelectorAll<HTMLButtonElement>('[role="option"]'))
    if (options.length === 0) return
    event.preventDefault()
    const index = options.indexOf(document.activeElement as HTMLButtonElement)
    const nextIndex = event.key === 'Home'
      ? 0
      : event.key === 'End'
        ? options.length - 1
        : index < 0
          ? 0
          : (index + (event.key === 'ArrowDown' ? 1 : -1) + options.length) % options.length
    options[nextIndex]?.focus()
  }
  return (
    <nav className="action-list" aria-label={`${group.shortLabel} actions`}>
      <button type="button" className="context-back-button" onClick={onBack}><ArrowLeftIcon aria-hidden="true" /> All sections</button>
      <div className="action-list-heading"><div><h1>{group.label}</h1></div><span className="section-count">{Object.keys(actions).length}</span></div>
      <p className="list-description">{group.description}</p>
      <div className="action-list-tools"><label className="search-field"><MagnifyingGlassIcon aria-hidden="true" /><span className="sr-only">Search {group.label}</span><input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Search actions" /></label>{supportsLifecycle && <div className="list-action-buttons"><button type="button" className="primary-button compact" onClick={onCreate} disabled={readOnly}><PlusIcon aria-hidden="true" /> New Insert</button></div>}</div>
      {supportsLifecycle && (createOpen || duplicateOpen) && <div className="create-panel"><strong className="create-panel-title">{duplicateOpen ? 'Duplicate Insert' : 'New Insert'}</strong><label>Name<input autoFocus value={createName} onChange={(event) => setCreateName(event.target.value)} onKeyDown={(event) => { if (event.key === 'Enter') onSubmitCreate() }} placeholder="e.g. meetingNotes" disabled={readOnly} /></label>{!duplicateOpen && <label>Payload<textarea value={createPayload} onChange={(event) => setCreatePayload(event.target.value)} rows={3} disabled={readOnly} /></label>}<div className="panel-actions"><button type="button" className="quiet-button" onClick={onCancelCreate}>Cancel</button><button type="button" className="primary-button compact" onClick={onSubmitCreate} disabled={readOnly || lifecycleStatus === 'saving'}>{lifecycleStatus === 'saving' ? 'Creating…' : duplicateOpen ? 'Duplicate' : 'Create Insert'}</button></div>{lifecycleError && <div className="panel-error" role="alert"><ExclamationTriangleIcon aria-hidden="true" />{lifecycleError}</div>}</div>}
      <div className="action-items" role="listbox" aria-label={`Available ${group.label}`} onKeyDown={onListKeyDown}>
        {names.map((name) => {
          const action = actions[name]
          return <button type="button" role="option" aria-selected={name === selectedName} className={name === selectedName ? 'action-item is-selected' : 'action-item'} key={name} onClick={() => onSelect(name)}><span className="action-item-icon">{action.icon || group.icon}</span><span className="action-item-copy"><strong title={name}>{actionDisplayName(name, action)}</strong><small>{actionDisplayDetail(name, action)}</small></span></button>
        })}
        {names.length === 0 && <div className="list-empty"><MagnifyingGlassIcon aria-hidden="true" /><span>{search ? `No matching ${group.label}` : `No ${group.label} yet`}</span>{supportsLifecycle && !search && <button type="button" className="text-button" onClick={onCreate} disabled={readOnly}>Create one</button>}</div>}
      </div>
    </nav>
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
  onRename: () => Promise<boolean>
  onDuplicate: () => void
  onDelete: () => void
  onBack: () => void
  lifecycleError: string
  lifecycleStatus: 'idle' | 'saving' | 'saved'
  editingBlocked?: boolean
  recoveredPayload?: string
  onRetainPayload: (text: string) => void
  onClearRetainedPayload: () => void
  folderPickerPreview: boolean
  chooseDirectory?: (purpose: FolderPickerPurpose) => Promise<string | null>
}

function InsertEditor({ snapshot, selectedName, action, drafts, valueFor, setDraftValue, commitField, revertField, retryField, resyncField, renameValue, setRenameValue, onRename, onDuplicate, onDelete, onBack, lifecycleError, lifecycleStatus, editingBlocked = false, recoveredPayload, onRetainPayload, onClearRetainedPayload, folderPickerPreview, chooseDirectory }: InsertEditorProps) {
  const actionPath = (field: string) => ['inserts', selectedName, field]
  const payloadPath = actionPath('action')
  const payloadEntry = drafts[pathKey(payloadPath)]
  const storedPayload = displayValue(valueFor(payloadPath))
  // Dirty drafts are already in the textarea's presentation form. Saving and
  // error states hold canonical text, as does the configuration snapshot.
  const payload = payloadEntry?.status === 'dirty' ? storedPayload : presentMacrowhisperInsertPayload(storedPayload)
  const payloadMode = storedPayload === '.autoPaste' ? 'autoPaste' : storedPayload === '.none' ? 'none' : 'text'
  const source = sourceForAction(selectedName, { ...action, action: storedPayload })
  const [placeholderOpen, setPlaceholderOpen] = useState(false)
  const [openDisclosure, setOpenDisclosure] = useState<'placeholders' | 'insertion' | 'conditions' | 'triggers' | 'chaining' | null>(source === 'invalid' ? 'conditions' : null)
  const [selectedPlaceholderIndex, setSelectedPlaceholderIndex] = useState<number | null>(null)
  const [inspectedPlaceholder, setInspectedPlaceholder] = useState<EditablePlaceholder | null>(null)
  const [pendingOverrides, setPendingOverrides] = useState<string[]>([])
  const [pendingConditions, setPendingConditions] = useState<string[]>([])
  const [conditionAdvanced, setConditionAdvanced] = useState(false)
  const [renaming, setRenaming] = useState(false)
  const composingRef = useRef(false)
  const deferredBlurRef = useRef(false)
  const textareaRef = useRef<HTMLTextAreaElement>(null)
  const selectionRef = useRef({ start: payload.length, end: payload.length })
  const boundaryRef = useRef<HTMLDivElement>(null)
  const selectedActionRef = useRef(selectedName)
  const conditionPath = actionPath('inputCondition')
  const conditionRaw = displayValue(valueFor(conditionPath))
  const conditionValues = parseCondition(conditionRaw)
  const conditionAnalysis = analyzeCondition(conditionRaw)
  const occurrences = useMemo(() => placeholderOccurrences(payload), [payload])
  const activeOccurrence = selectedPlaceholderIndex === null ? null : occurrences[selectedPlaceholderIndex] ?? null

  const rememberSelection = () => {
    const element = textareaRef.current
    if (element) {
      selectionRef.current = { start: element.selectionStart, end: element.selectionEnd }
    }
  }

  useEffect(() => {
    if (selectedPlaceholderIndex !== null && selectedPlaceholderIndex >= occurrences.length) {
      setSelectedPlaceholderIndex(null)
      setInspectedPlaceholder(null)
    }
  }, [occurrences.length, selectedPlaceholderIndex])

  useEffect(() => {
    if (selectedActionRef.current === selectedName) return
    selectedActionRef.current = selectedName
    setSelectedPlaceholderIndex(null)
    setInspectedPlaceholder(null)
    setPlaceholderOpen(false)
    setOpenDisclosure(source === 'invalid' ? 'conditions' : null)
  }, [selectedName, source])

  const setDisclosureOpen = (disclosure: 'placeholders' | 'insertion' | 'conditions' | 'triggers' | 'chaining', open: boolean) => {
    setOpenDisclosure((current) => open ? disclosure : current === disclosure ? null : current)
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
    const currentPayload = payload
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
    setOpenDisclosure((current) => current === 'placeholders' ? null : current)
    requestAnimationFrame(() => {
      if (!element) return
      element.focus()
      const caret = safeStart + insertion.length
      element.setSelectionRange(caret, caret)
      selectionRef.current = { start: caret, end: caret }
      setSelectedPlaceholderIndex(null)
      setInspectedPlaceholder(null)
    })
  }

  const updatePlaceholder = (next: EditablePlaceholder) => {
    const currentPayload = payload
    const prefix = next.prefixType ? `${next.prefixType}:` : ''
    const source = next.xmlTag !== undefined ? `xml:${next.xmlTag}` : next.key
    const format = next.xmlTag !== undefined ? '' : next.format ? `:${next.format}` : next.key === 'date' ? ':short' : ''
    const transform = next.transformName ? `::${next.transformName}` : ''
    const replacements = next.regexReplacements
      .map((stage) => `||${regexBuilderPart(stage.find)}||${regexBuilderPart(serializeMacrowhisperReplacement(stage.replace))}`)
      .join('')
    const raw = `{{${prefix}${source}${format}${transform}${replacements}}}`
    const updatedPayload = `${currentPayload.slice(0, next.start)}${raw}${currentPayload.slice(next.end)}`
    const updated = { ...next, end: next.start + raw.length, raw }
    setDraftValue(payloadPath, updatedPayload)
    setInspectedPlaceholder(updated)
    requestAnimationFrame(() => {
      textareaRef.current?.setSelectionRange(updated.start, updated.end)
      selectionRef.current = { start: updated.start, end: updated.end }
    })
  }

  const selectPlaceholder = (index: number) => {
    if (selectedPlaceholderIndex === index) {
      setSelectedPlaceholderIndex(null)
      setInspectedPlaceholder(null)
      return
    }
    const occurrence = occurrences[index]
    if (!occurrence) return
    setSelectedPlaceholderIndex(index)
    setInspectedPlaceholder(occurrence.placeholder)
    requestAnimationFrame(() => {
      const element = textareaRef.current
      if (!element) return
      element.focus()
      element.setSelectionRange(occurrence.start, occurrence.end)
      selectionRef.current = { start: occurrence.start, end: occurrence.end }
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
    if (entry?.status === 'dirty') void commitField(payloadPath, serializeMacrowhisperInsertPayload(displayValue(entry.value)))
  }

  const onPlaceholderKey = (event: React.KeyboardEvent<HTMLDivElement>) => {
    const items = Array.from(event.currentTarget.querySelectorAll<HTMLButtonElement>('[role="menuitem"]'))
    const index = items.indexOf(document.activeElement as HTMLButtonElement)
    if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) {
      event.preventDefault()
      const next = event.key === 'Home' || (index < 0 && event.key === 'ArrowDown')
        ? 0
        : event.key === 'End' || (index < 0 && event.key === 'ArrowUp')
          ? items.length - 1
          : (index + (event.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length
      items[next]?.focus()
    }
  }

  useEffect(() => {
    if (placeholderOpen) boundaryRef.current?.querySelector<HTMLElement>('[role="menu"]')?.focus({ preventScroll: true })
  }, [placeholderOpen])

  const setActionChoice = async (next: 'autoPaste' | 'none' | 'text') => {
    if (next === payloadMode) return
    if (payloadMode === 'text' && next !== 'text' && payload.length > 0) onRetainPayload(payload)
    if (next === 'autoPaste') await commitField(payloadPath, '.autoPaste')
    else if (next === 'none') await commitField(payloadPath, '.none')
    else {
      const restored = recoveredPayload ?? ''
      const saved = await commitField(payloadPath, serializeMacrowhisperInsertPayload(restored))
      if (saved && recoveredPayload !== undefined) onClearRetainedPayload()
    }
  }

  useEffect(() => {
    if (payloadMode === 'text' && recoveredPayload !== undefined) onClearRetainedPayload()
  }, [payloadMode, recoveredPayload, onClearRetainedPayload])

  const cancelRename = () => {
    setRenameValue(selectedName)
    setRenaming(false)
  }

  const saveRename = async () => {
    const saved = await onRename()
    if (saved) setRenaming(false)
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
  const triggerKinds = [
    ['triggerVoice', 'voice phrase', 'voice phrases'],
    ['triggerApps', 'front app', 'front apps'],
    ['triggerModes', 'Superwhisper mode', 'Superwhisper modes'],
    ['triggerUrls', 'browser URL', 'browser URLs'],
  ] as const
  const triggerParts = triggerKinds.flatMap(([field, singular, plural]) => {
    const raw = displayValue(valueFor(actionPath(field)))
    if (!raw) return []
    const count = isStructuredTriggerExpression(raw, field) ? parseTriggerTokens(raw, field).length : 1
    return [`${count} ${count === 1 ? singular : plural}`]
  })
  const joinSummaryParts = (parts: string[]) => parts.length <= 1 ? (parts[0] ?? '') : `${parts.slice(0, -1).join(', ')} and ${parts.at(-1)}`
  const effectiveTriggerLogic = displayValue(valueFor(actionPath('triggerLogic'))) || displayValue(effectiveDefault(snapshot, 'triggerLogic')) || 'or'
  const triggerSummary = triggerParts.length === 0
    ? 'No triggers; available as a fallback or chain step'
    : `Triggered by ${joinSummaryParts(triggerParts)}${triggerParts.length > 1 ? ` (${effectiveTriggerLogic === 'and' ? 'all types must match' : 'any type can match'})` : ''}`
  const payloadSummary = payloadMode === 'autoPaste' ? 'Uses built-in Auto-paste' : payloadMode === 'none' ? 'Performs no payload' : 'Inserts custom text'
  const insertionSummary = payloadMode === 'text'
    ? (overrideCount === 0 ? 'Uses Defaults' : `${overrideCount} action override${overrideCount === 1 ? '' : 's'}`)
    : 'Uses built-in insertion behavior'
  const conditionsSummary = payloadMode === 'text'
    ? conditionHasIssue
      ? 'Input conditions need review'
      : conditionRaw
        ? `${Object.keys(conditionValues).length} input condition${Object.keys(conditionValues).length === 1 ? '' : 's'}`
        : 'No input conditions'
    : 'Uses built-in input conditions'
  const nextActionValue = valueFor(actionPath('nextAction'))
  const inheritedNextAction = displayValue(effectiveDefault(snapshot, 'nextAction'))
  const resolvedNextAction = nextActionValue === null || nextActionValue === undefined ? inheritedNextAction : displayValue(nextActionValue)
  const nextActionRecord = groups.flatMap((group) => Object.entries(snapshot[group.id])).find(([name]) => name === resolvedNextAction)?.[1]
  const nextActionLabel = resolvedNextAction ? actionDisplayName(resolvedNextAction, nextActionRecord) : ''
  const nextSummary = nextActionValue === null || nextActionValue === undefined
    ? resolvedNextAction
      ? `Uses Defaults next step (${nextActionLabel}) when first in a chain`
      : 'Stops after this action'
    : resolvedNextAction
      ? `Continues to ${nextActionLabel}`
      : 'Stops after this action'
  const effectiveBehavior = `${triggerSummary} · ${payloadSummary} · ${insertionSummary} · ${conditionsSummary} · ${nextSummary}`
  const insertionDisclosureMeta = payloadMode === 'text'
    ? (overrideCount === 0 ? 'Uses Defaults' : `${overrideCount} override${overrideCount === 1 ? '' : 's'}`)
    : `Built-in active${overrideCount > 0 ? ` · ${overrideCount} stored override${overrideCount === 1 ? '' : 's'}` : ''}`
  const conditionDisclosureMeta = payloadMode === 'text'
    ? conditionSummary
    : `Built-in active${conditionRaw ? ' · Stored rules retained' : ''}`
  const addOverrideControl = availableOverrides.length > 0 ? <label className="add-setting-control insertion-add-control"><span className="sr-only">Add override</span><PlusIcon aria-hidden="true" /><select aria-label="Add override" value="" onChange={(event) => { const field = event.target.value; if (field) setPendingOverrides((current) => [...current, field]) }}><option value="">Add override…</option>{availableOverrides.map((field) => <option key={field} value={field}>{actionMeta[field].label}</option>)}</select></label> : null

  return (
    <section className="insert-editor">
      <div className="editor-scroll">
        <button type="button" className="back-button mobile-action-back" onClick={onBack}><ArrowLeftIcon aria-hidden="true" /> Inserts</button>

        <section className="action-overview-card" aria-labelledby="insert-editor-title">
          <div className="action-overview-heading">
            <div className="action-overview-identity">
              <div className="action-title-line">
                {renaming ? <><h1 id="insert-editor-title" className="sr-only">{selectedName}</h1><div className="action-title-editor"><label className="sr-only" htmlFor="insert-name">Action name</label><input id="insert-name" autoFocus value={renameValue} onChange={(event) => setRenameValue(event.target.value)} onKeyDown={(event) => { if (event.key === 'Enter') { event.preventDefault(); void saveRename() } else if (event.key === 'Escape') { event.preventDefault(); cancelRename() } }} disabled={editingBlocked} /><button type="button" className="primary-button compact" onClick={() => void saveRename()} disabled={editingBlocked || lifecycleStatus === 'saving' || !renameValue.trim()}>Save name</button><button type="button" className="quiet-button compact" onClick={cancelRename}>Cancel</button></div></> : <><h1 id="insert-editor-title" title={selectedName}>{selectedName}</h1><button type="button" className="quiet-button compact rename-action-button" onClick={() => setRenaming(true)} disabled={editingBlocked}><Pencil1Icon aria-hidden="true" /> Rename</button></>}
                <SourcePill source={source} />
              </div>
              <p className="screen-description">{groupById.get('inserts')?.description}</p>
              <FieldLifecycle status={lifecycleStatus} />
            </div>
            <div className="action-overview-actions"><button type="button" className="quiet-button" onClick={onDuplicate} disabled={editingBlocked}><CopyIcon aria-hidden="true" /> Duplicate</button><button type="button" className="quiet-button danger-button" onClick={onDelete} disabled={editingBlocked || payload === '.autoPaste'} aria-label={payload === '.autoPaste' ? 'Delete unavailable: built-in auto-paste cannot be deleted' : 'Delete'} title={payload === '.autoPaste' ? 'The built-in auto-paste action cannot be deleted' : undefined}><TrashIcon aria-hidden="true" /> Delete</button></div>
          </div>
          {lifecycleError && <div className="inline-field-error" role="alert"><ExclamationTriangleIcon aria-hidden="true" />{lifecycleError}</div>}
          <div className="effective-summary" aria-label="Effective behavior"><strong>Effective behavior</strong><p>{effectiveBehavior}</p></div>
        </section>

        {source === 'invalid' && <div className="field-alert" role="alert"><ExclamationTriangleIcon aria-hidden="true" /><div><strong>This action has invalid configuration.</strong><span>Fix the highlighted fields before saving another change. Existing text is preserved so you can repair it deliberately.</span></div></div>}

        <section className="editor-section payload-section insert-card">
          <div className="insert-card-heading payload-heading">
            <div><h2>Payload</h2><p>Choose a built-in mode or write Custom text. Placeholder helpers only appear for Custom text.</p></div>
            <a className="section-heading-link" href="https://github.com/ognistik/macrowhisper/blob/main/docs/placeholders-and-context.md" target="_blank" rel="noreferrer">Placeholder syntax reference <UpdateIcon aria-hidden="true" /></a>
          </div>
          <div className="payload-mode-row">
            <div><label htmlFor="payload-mode">What should this Insert do?</label><p>The mode controls the payload Macrowhisper sends to the focused app.</p></div>
            <select id="payload-mode" aria-label="Payload mode" value={payloadMode} onChange={(event) => void setActionChoice(event.target.value as 'autoPaste' | 'none' | 'text')}>
              <option value="autoPaste">Auto-paste dictation</option>
              <option value="none">Do nothing</option>
              <option value="text">Insert custom text</option>
            </select>
          </div>
          {payloadMode === 'text' ? <div className="payload-boundary" ref={boundaryRef} onBlur={onPayloadBlur}>
            <div className="payload-toolbar">
              <span>Custom text</span>
              <div className="placeholder-menu"><button type="button" className="toolbar-button" aria-haspopup="menu" aria-expanded={placeholderOpen} aria-controls="insert-placeholder-menu" onMouseDown={(event) => event.preventDefault()} onClick={() => { rememberSelection(); setPlaceholderOpen((open) => !open) }}><PlusIcon aria-hidden="true" /> Insert placeholder <ChevronDownIcon aria-hidden="true" /></button>{placeholderOpen && <PlaceholderMenu onInsert={insertExpression} onKeyDown={onPlaceholderKey} />}</div>
            </div>
            <textarea ref={textareaRef} value={payload} aria-label="Insert payload" aria-describedby={payloadEntry?.error ? fieldErrorId(payloadPath) : undefined} rows={8} onChange={(event) => { setDraftValue(payloadPath, event.target.value); setSelectedPlaceholderIndex(null); setInspectedPlaceholder(null) }} onSelect={rememberSelection} onKeyUp={rememberSelection} onFocus={rememberSelection} onCompositionStart={() => { composingRef.current = true }} onCompositionEnd={(event) => {
          composingRef.current = false
          if (deferredBlurRef.current) {
            deferredBlurRef.current = false
            void commitField(payloadPath, serializeMacrowhisperInsertPayload(event.currentTarget.value))
          }
        }} placeholder="Type the text to insert…" />
            <PlaceholderReview occurrences={occurrences} open={openDisclosure === 'placeholders'} selectedIndex={selectedPlaceholderIndex} onToggle={(open) => setDisclosureOpen('placeholders', open)} onSelect={selectPlaceholder} />
            {openDisclosure === 'placeholders' && activeOccurrence && (inspectedPlaceholder
              ? <PlaceholderInspector placeholder={inspectedPlaceholder} onChange={updatePlaceholder} />
              : <RawPlaceholderInspector occurrence={activeOccurrence} />)}
            <div className="payload-footer"><span>{payload.length} characters</span><FieldState entry={payloadEntry} onRevert={() => revertField(payloadPath)} onRetry={() => retryField(payloadPath)} onResync={() => resyncField(payloadPath)} errorId={fieldErrorId(payloadPath)} /></div>
          </div> : <div className="payload-template-summary"><div><strong>{payloadMode === 'autoPaste' ? 'Auto-paste dictation' : 'Do nothing'}</strong><span>{payloadMode === 'autoPaste' ? 'Macrowhisper uses its protected built-in paste flow and insertion behavior. This action cannot be deleted.' : 'This Insert performs no payload operation. Its triggers and chain settings can still apply.'}</span></div>{recoveredPayload !== undefined && <div className="payload-recovery" role="status"><div><strong>Custom text retained</strong><span>{recoveredPayload.length} character{recoveredPayload.length === 1 ? '' : 's'} kept for this editing session.</span></div><button type="button" className="quiet-button" onClick={() => void setActionChoice('text')}>Restore custom text</button></div>}</div>}
        </section>

        <div className="editor-section insert-disclosure-section settings-section"><Disclosure title="Action overrides" subtitle="Change inherited Defaults for this action." meta={insertionDisclosureMeta} open={openDisclosure === 'insertion'} onToggle={(open) => setDisclosureOpen('insertion', open)} variant="defaults">
          {visibleOverrides.length === 0 && <div className="section-empty insertion-empty-state"><div className="insertion-empty-copy"><strong>Using Defaults</strong></div>{addOverrideControl}</div>}
          <div className="configured-list">{visibleOverrides.map((field) => {
            const configured = configuredOverrides.includes(field)
            const disabled = payloadMode !== 'text' && (field === 'simEsc' || field === 'restoreClipboard')
            const disabledNote = disabled ? `${payloadMode === 'autoPaste' ? 'Template: Off outside text fields; Defaults inside text fields.' : 'Template: Off.'} Stored override is retained.` : undefined
            const removeLabel = configured ? `Remove ${actionMeta[field].label} override` : `Cancel adding ${actionMeta[field].label} override`
            const utility = <button type="button" className="remove-configured" aria-label={removeLabel} onClick={() => { setPendingOverrides((current) => current.filter((item) => item !== field)); if (configured) void commitField(actionPath(field), null) }}><Cross2Icon aria-hidden="true" /></button>
            return <div className="configured-item" key={field}><OverrideField field={field} path={actionPath(field)} value={valueFor(actionPath(field))} entry={drafts[pathKey(actionPath(field))]} meta={actionMeta[field]} pending={!configured} onChoice={(value) => { void commitField(actionPath(field), value); if (value !== null && value !== undefined) setPendingOverrides((current) => current.filter((item) => item !== field)) }} onText={(value) => setDraftValue(actionPath(field), value)} onBlur={(value) => { commitIfChanged(actionPath(field), value); setPendingOverrides((current) => current.filter((item) => item !== field)) }} onRevert={() => revertField(actionPath(field))} onRetry={() => retryField(actionPath(field))} onResync={() => resyncField(actionPath(field))} folderPickerPreview={folderPickerPreview} chooseDirectory={chooseDirectory} disabled={disabled} disabledNote={disabledNote} utility={utility} /></div>
          })}</div>
          {visibleOverrides.length > 0 && addOverrideControl && <div className="insertion-footer">{addOverrideControl}</div>}
        </Disclosure></div>

        <div className="editor-section insert-disclosure-section settings-section"><Disclosure title="Conditions" subtitle="Apply supported settings inside or outside text fields." meta={conditionDisclosureMeta} open={openDisclosure === 'conditions'} onToggle={(open) => setDisclosureOpen('conditions', open)} variant="defaults">
          <div className="condition-intro">Add a rule only when a setting should behave differently inside or outside a text field.</div>
          {conditionHasIssue && <div className="inline-field-error"><ExclamationTriangleIcon aria-hidden="true" />This saved expression contains {conditionAnalysis.malformed ? 'an invalid token' : conditionAnalysis.repeated.length > 0 ? `repeated token${conditionAnalysis.repeated.length === 1 ? '' : 's'}` : 'a token this editor cannot represent'}. It stays intact until you deliberately edit Advanced raw mode.</div>}
          <fieldset className="template-field" disabled={payloadMode !== 'text' || conditionHasIssue || conditionAdvanced}>{payloadMode !== 'text' && <p className="template-note">The built-in mode supplies its own conditions. Your stored expression is retained for Custom text.</p>}{conditionHasIssue && !conditionAdvanced && <p className="template-note">Structured controls are paused until you enable Edit raw expression.</p>}{visibleConditions.length === 0 && !conditionHasIssue && <div className="section-empty"><strong>Always</strong><span>No conditional behavior is configured.</span></div>}<div className="condition-list">{visibleConditions.map((field) => <div className="condition-row" key={field}><div><strong>{field === 'action' ? 'Payload' : actionMeta[field]?.label ?? field}</strong><span>{field === 'action' ? 'Text or built-in action value' : 'Choose where this rule applies'}</span></div><select aria-label={`Condition for ${field}`} value={conditionValues[field] ?? ''} onChange={(event) => setConditionMode(field, event.target.value as 'inside' | 'outside')}><option value="" disabled>Choose…</option><option value="inside">Only in a text field</option><option value="outside">Only outside text fields</option></select><button type="button" className="icon-button" aria-label={`Remove condition for ${field}`} onClick={() => setConditionMode(field, 'always')}><Cross2Icon aria-hidden="true" /></button></div>)}</div>{availableConditions.length > 0 && !conditionHasIssue && <label className="add-setting-control"><span className="sr-only">Add condition</span><PlusIcon aria-hidden="true" /><select aria-label="Add condition" value="" onChange={(event) => { const field = event.target.value; if (field) setPendingConditions((current) => [...current, field]) }}><option value="">Add condition…</option>{availableConditions.map((field) => <option key={field} value={field}>{field === 'action' ? 'Payload' : actionMeta[field]?.label ?? field}</option>)}</select></label>}</fieldset>
          <div className="generated-expression"><span>Generated expression</span><code>{conditionRaw || 'Always'}</code></div><label className="advanced-toggle"><input type="checkbox" checked={conditionAdvanced} onChange={(event) => setConditionAdvanced(event.target.checked)} /> Edit raw expression</label><div className="raw-expression"><input aria-label="Advanced input condition" readOnly={!conditionAdvanced} value={conditionRaw} aria-describedby={drafts[pathKey(conditionPath)]?.error ? fieldErrorId(conditionPath) : undefined} onChange={(event) => { if (conditionAdvanced) setDraftValue(conditionPath, event.target.value) }} onBlur={(event) => { if (conditionAdvanced) commitIfChanged(conditionPath, event.target.value) }} /><span>{conditionAdvanced ? 'Raw mode is deliberate; existing text is preserved until you edit it.' : 'Read-only preview. Enable Edit raw expression only for syntax this builder cannot represent.'}</span><FieldState entry={drafts[pathKey(conditionPath)]} onRevert={() => revertField(conditionPath)} onRetry={() => retryField(conditionPath)} onResync={() => resyncField(conditionPath)} errorId={fieldErrorId(conditionPath)} /></div>
        </Disclosure></div>

        <TriggerEditor action={action} selectedName={selectedName} actionPath={actionPath} drafts={drafts} valueFor={valueFor} setDraftValue={setDraftValue} commitIfChanged={commitIfChanged} commitField={commitField} revertField={revertField} retryField={retryField} resyncField={resyncField} open={openDisclosure === 'triggers'} onToggle={(open) => setDisclosureOpen('triggers', open)} />

        <div className="editor-section insert-disclosure-section settings-section"><Disclosure title="Chaining" subtitle="Continue to another action after this step." meta={valueFor(actionPath('nextAction')) ? 'Linked' : 'No next action'} open={openDisclosure === 'chaining'} onToggle={(open) => setDisclosureOpen('chaining', open)} variant="defaults"><div className="chain-field"><label htmlFor="next-action">Next action</label><p>The Defaults next action applies only to the root step. Select an action from any group.</p><ActionPicker id="next-action" label="Next action" describedBy={drafts[pathKey(actionPath('nextAction'))]?.error ? fieldErrorId(actionPath('nextAction')) : undefined} value={valueFor(actionPath('nextAction')) === null || valueFor(actionPath('nextAction')) === undefined ? NULL_CHOICE : valueFor(actionPath('nextAction')) === '' ? EMPTY_CHOICE : displayValue(valueFor(actionPath('nextAction')))} options={[
          { value: NULL_CHOICE, label: 'Use Defaults next action', detail: 'Only for the first step', group: 'Defaults', keywords: 'inherit root' },
          { value: EMPTY_CHOICE, label: 'Stop chain', detail: 'Do not continue to another action', group: 'Chain behavior', keywords: 'none stop' },
          ...actionOptions(snapshot, ['inserts', selectedName]),
        ]} onChange={(selectedValue) => { const next = selectedValue === NULL_CHOICE ? null : selectedValue === EMPTY_CHOICE ? '' : selectedValue; void commitField(actionPath('nextAction'), next) }} />{action.nextAction === 'does-not-exist' && <div className="inline-field-error"><ExclamationTriangleIcon aria-hidden="true" />The saved link “does-not-exist” is unavailable. Choose another action or Stop chain.</div>}{drafts[pathKey(actionPath('nextAction'))] && <FieldState entry={drafts[pathKey(actionPath('nextAction'))]} onRevert={() => revertField(actionPath('nextAction'))} onRetry={() => retryField(actionPath('nextAction'))} onResync={() => resyncField(actionPath('nextAction'))} errorId={fieldErrorId(actionPath('nextAction'))} />}</div></Disclosure></div>
      </div>
    </section>
  )
}

function PlaceholderMenu({ onInsert, onKeyDown }: { onInsert: (expression: string) => void; onKeyDown: (event: React.KeyboardEvent<HTMLDivElement>) => void }) {
  const [activeKey, setActiveKey] = useState<string | null>(null)

  return (
    <div className={`placeholder-popover${activeKey ? ' is-keyboard-navigating' : ''}`} id="insert-placeholder-menu" role="menu" aria-label="Insert placeholder" tabIndex={-1} onKeyDown={onKeyDown} onPointerMove={() => setActiveKey(null)}>
      <div className="placeholder-popover-heading"><strong>Insert placeholder</strong><span>Choose a value to insert.</span></div>
      <div className="placeholder-source-groups">
        {placeholderGroups.map((group) => {
          const groupId = `placeholder-group-${group.label.toLowerCase().replaceAll(' ', '-')}`
          return <div className="placeholder-group" role="group" aria-labelledby={groupId} key={group.label}><span className="placeholder-group-title" id={groupId}>{group.label}</span><div className="placeholder-option-list">{group.items.map((item) => {
            const labelId = `placeholder-${item.key}-label`
            const hintId = `placeholder-${item.key}-hint`
            return <button type="button" role="menuitem" aria-labelledby={labelId} aria-describedby={hintId} className={activeKey === item.key ? 'is-keyboard-active' : undefined} tabIndex={activeKey === item.key ? 0 : -1} key={item.key} onFocus={() => setActiveKey(item.key)} onMouseDown={(event) => event.preventDefault()} onClick={() => onInsert(`{{${item.key}}}`)}><strong id={labelId}>{item.label}</strong><small id={hintId}>{item.hint}</small></button>
          })}</div></div>
        })}
        <div className="placeholder-group date-placeholder" role="group" aria-labelledby="placeholder-group-date"><span className="placeholder-group-title" id="placeholder-group-date">Date and time</span><div className="placeholder-option-list">{dateFormats.map((format) => {
          const id = format.value.replaceAll(/[^a-zA-Z0-9]+/g, '-')
          const key = `date:${format.value}`
          return <button type="button" role="menuitem" aria-labelledby={`placeholder-date-${id}-label`} aria-describedby={`placeholder-date-${id}-hint`} className={activeKey === key ? 'is-keyboard-active' : undefined} tabIndex={activeKey === key ? 0 : -1} key={format.value} onFocus={() => setActiveKey(key)} onMouseDown={(event) => event.preventDefault()} onClick={() => onInsert(`{{${key}}}`)}><strong id={`placeholder-date-${id}-label`}>{format.label}</strong><small id={`placeholder-date-${id}-hint`}>{format.hint}</small></button>
        })}</div></div>
      </div>
    </div>
  )
}

function PlaceholderReview({ occurrences, open, selectedIndex, onToggle, onSelect }: { occurrences: PlaceholderOccurrence[]; open: boolean; selectedIndex: number | null; onToggle: (open: boolean) => void; onSelect: (index: number) => void }) {
  const count = occurrences.length
  const onListKeyDown = (event: React.KeyboardEvent<HTMLDivElement>) => {
    if (!['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) return
    const options = Array.from(event.currentTarget.querySelectorAll<HTMLButtonElement>('[role="option"]'))
    const current = options.indexOf(document.activeElement as HTMLButtonElement)
    event.preventDefault()
    const next = event.key === 'Home' ? 0 : event.key === 'End' ? options.length - 1 : (current + (event.key === 'ArrowDown' ? 1 : -1) + options.length) % options.length
    options[next]?.focus()
  }
  return <section className="placeholder-review" aria-label="Detected placeholders">
    <button type="button" className="placeholder-review-toggle" aria-expanded={open} aria-controls="placeholder-occurrence-list" onClick={() => onToggle(!open)} disabled={count === 0}>
      <CodeIcon aria-hidden="true" />
      <span><strong>{count === 0 ? 'No placeholders found' : `${count} placeholder${count === 1 ? '' : 's'} found`}</strong><small>{count === 0 ? 'Type double curly brackets or use Insert placeholder.' : open ? 'Choose an occurrence to inspect it.' : 'Review sources, transforms, and replacements.'}</small></span>
      {count > 0 && <ChevronDownIcon aria-hidden="true" />}
    </button>
    {open && count > 0 && <div id="placeholder-occurrence-list" className="placeholder-occurrence-list" role="listbox" aria-label="Placeholder occurrences" onKeyDown={onListKeyDown}>
      {occurrences.map((occurrence) => <button type="button" role="option" aria-selected={selectedIndex === occurrence.index} className={selectedIndex === occurrence.index ? 'is-selected' : ''} key={`${occurrence.start}-${occurrence.raw}`} onClick={() => onSelect(occurrence.index)}><span className="occurrence-number">{occurrence.index + 1}</span><span className="occurrence-copy"><strong>{occurrence.label}</strong><code>{occurrence.raw}</code></span><span className="occurrence-meta">{occurrence.placeholder ? occurrence.placeholder.regexReplacements.length > 0 ? `${occurrence.placeholder.regexReplacements.length} replacement${occurrence.placeholder.regexReplacements.length === 1 ? '' : 's'}` : occurrence.placeholder.transformName ? 'Transformed' : 'Plain' : 'Raw syntax'}</span></button>)}
    </div>}
  </section>
}

function RawPlaceholderInspector({ occurrence }: { occurrence: PlaceholderOccurrence }) {
  return <section className="placeholder-inspector raw-placeholder-inspector" aria-label="Edit placeholder">
    <div className="placeholder-inspector-heading"><div><strong>Raw placeholder</strong><span>This occurrence uses syntax the visual inspector cannot safely rewrite.</span></div><code>{occurrence.raw}</code></div>
    <p>Edit it directly in Custom text. Its exact syntax remains untouched when you review other placeholders.</p>
  </section>
}

function regexBuilderPart(value: string): string {
  let encoded = ''
  for (let index = 0; index < value.length; index += 1) {
    const character = value[index]
    if (character === '|' && value[index + 1] === '|') {
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
  let trailingSlashes = 0
  for (let index = encoded.length - 1; index >= 0 && encoded[index] === '\\'; index -= 1) trailingSlashes += 1
  if (trailingSlashes % 2 === 1) encoded += '\\'
  return encoded
}

function regexPatternError(pattern: string): string | null {
  if (!pattern) return 'Add a find pattern before this replacement can run.'
  try {
    new RegExp(pattern)
    return null
  } catch {
    return 'Browser check could not parse this pattern. Macrowhisper uses Apple regular expressions, so review it before saving.'
  }
}

function PlaceholderIndexField({ placeholder, onChange }: { placeholder: EditablePlaceholder; onChange: (placeholder: EditablePlaceholder) => void }) {
  const sourceValue = placeholder.format ?? ''
  const [draftValue, setDraftValue] = useState(sourceValue)
  const fieldIdentity = `${placeholder.start}-${placeholder.key}`
  const errorId = `placeholder-index-error-${placeholder.start}`
  const hintId = `placeholder-index-hint-${placeholder.start}`

  useEffect(() => {
    setDraftValue(sourceValue)
  }, [fieldIdentity, sourceValue])

  const invalid = draftValue !== '' && !/^\d+$/.test(draftValue)

  return <label className="placeholder-argument-field">Source index
    <input
      aria-label="Placeholder index"
      aria-invalid={invalid || undefined}
      aria-describedby={invalid ? errorId : hintId}
      inputMode="numeric"
      pattern="[0-9]*"
      value={draftValue}
      onChange={(event) => {
        const nextValue = event.target.value
        setDraftValue(nextValue)
        if (nextValue === '' || /^\d+$/.test(nextValue)) {
          onChange({ ...placeholder, format: nextValue || undefined })
        }
      }}
      placeholder="Latest"
    />
    {invalid
      ? <small className="placeholder-index-validation" id={errorId} role="status">Use digits only (0 or greater). The placeholder stays unchanged until this is valid.</small>
      : <small id={hintId}>Optional, zero-based. Leave empty for the current value.</small>}
  </label>
}

function PlaceholderInspector({ placeholder, onChange }: { placeholder: EditablePlaceholder; onChange: (placeholder: EditablePlaceholder) => void }) {
  const updateStage = (index: number, next: ReplacementStage) => onChange({ ...placeholder, regexReplacements: placeholder.regexReplacements.map((stage, stageIndex) => stageIndex === index ? next : stage) })
  const moveStage = (index: number, direction: -1 | 1) => {
    const target = index + direction
    if (target < 0 || target >= placeholder.regexReplacements.length) return
    const stages = [...placeholder.regexReplacements]
    ;[stages[index], stages[target]] = [stages[target], stages[index]]
    onChange({ ...placeholder, regexReplacements: stages })
  }
  const builtInSource = placeholders.some((source) => source.key === placeholder.key)
  const xmlSource = placeholder.xmlTag !== undefined
  const customSource = !builtInSource && !xmlSource && placeholder.key !== 'date'
  const knownTransform = !placeholder.transformName || placeholderTransforms.some((transform) => transform.key === placeholder.transformName)
  const indexedSource = ['actionResult', 'folderName', 'folderPath'].includes(placeholder.key)
  const sourceValue = placeholder.key === 'date' ? `date:${placeholder.format ?? 'short'}` : placeholder.key
  const currentDateFormat = placeholder.key === 'date' ? placeholder.format ?? 'short' : null
  const setSource = (value: string) => {
    if (value.startsWith('date:')) {
      onChange({ ...placeholder, key: 'date', format: value.slice('date:'.length) || 'short' })
      return
    }
    const preserveIndex = value === placeholder.key && ['actionResult', 'folderName', 'folderPath'].includes(value)
    onChange({ ...placeholder, key: value, format: preserveIndex ? placeholder.format : undefined })
  }
  return <section className="placeholder-inspector" aria-label="Edit placeholder">
    <div className="placeholder-inspector-heading"><div><strong>Occurrence inspector</strong><span>Changes apply only to the selected occurrence.</span></div><code>{placeholder.raw}</code></div>
    <div className="placeholder-inspector-grid">
      {xmlSource
        ? <div className="placeholder-fixed-source"><span>XML tag</span><code>{placeholder.xmlTag}</code></div>
        : customSource
          ? <div className="placeholder-fixed-source"><span>Source</span><code>{placeholder.key}</code></div>
        : <label>Source<select aria-label="Placeholder source" value={sourceValue} onChange={(event) => setSource(event.target.value)}>{placeholderGroups.map((group) => <optgroup label={group.label} key={group.label}>{group.items.map((item) => <option key={item.key} value={item.key}>{item.label}</option>)}</optgroup>)}<optgroup label="Date and time">{currentDateFormat && !dateFormats.some((format) => format.value === currentDateFormat) && <option value={`date:${currentDateFormat}`}>Custom date · {currentDateFormat}</option>}{dateFormats.map((format) => <option key={format.value} value={`date:${format.value}`}>{format.label}</option>)}</optgroup></select></label>}
      <label>Transform<select aria-label="Placeholder transform" value={placeholder.transformName ?? ''} onChange={(event) => onChange({ ...placeholder, transformName: event.target.value || undefined })}><option value="">No transform</option>{!knownTransform && placeholder.transformName && <option value={placeholder.transformName}>Custom · {placeholder.transformName}</option>}{['Text case', 'Identifiers', 'Titles', 'Specialized'].map((group) => <optgroup label={group} key={group}>{placeholderTransforms.filter((item) => item.group === group).map((item) => <option key={item.key} value={item.key}>{item.label}</option>)}</optgroup>)}</select></label>
      {indexedSource && <PlaceholderIndexField placeholder={placeholder} onChange={onChange} />}
      {customSource && placeholder.format !== undefined && <label className="placeholder-argument-field">Argument<input aria-label="Placeholder argument" value={placeholder.format} onChange={(event) => onChange({ ...placeholder, format: event.target.value || undefined })} /><small>Preserved after the custom source name.</small></label>}
    </div>
    <div className="replacement-editor"><div className="replacement-editor-heading"><div><strong>Regex replacements</strong><span>{placeholder.regexReplacements.length === 0 ? 'No replacements' : `${placeholder.regexReplacements.length} stage${placeholder.regexReplacements.length === 1 ? '' : 's'} · applied top to bottom`}</span></div><button type="button" className="text-button" onClick={() => onChange({ ...placeholder, regexReplacements: [...placeholder.regexReplacements, { find: '', replace: '' }] })}><PlusIcon aria-hidden="true" /> Add replacement</button></div>
      {placeholder.regexReplacements.length === 0 && <div className="replacement-empty"><span>Use replacements for cleanup that a single transform cannot handle.</span><small>Capture text with parentheses, reuse it with <code>{'${1}'}</code>, or transform a capture with <code>{'${1::uppercase}'}</code>.</small></div>}
      {placeholder.regexReplacements.map((stage, index) => {
        const patternError = regexPatternError(stage.find)
        return <div className="replacement-stage" key={index}><div className="replacement-stage-heading"><strong>Replacement {index + 1}</strong><div><button type="button" className="stage-icon-action" aria-label={`Move replacement ${index + 1} up`} disabled={index === 0} onClick={() => moveStage(index, -1)}><ArrowUpIcon aria-hidden="true" /></button><button type="button" className="stage-icon-action" aria-label={`Move replacement ${index + 1} down`} disabled={index === placeholder.regexReplacements.length - 1} onClick={() => moveStage(index, 1)}><ArrowDownIcon aria-hidden="true" /></button><button type="button" className="stage-icon-action stage-icon-remove" aria-label={`Remove replacement ${index + 1}`} onClick={() => onChange({ ...placeholder, regexReplacements: placeholder.regexReplacements.filter((_, stageIndex) => stageIndex !== index) })}><Cross2Icon aria-hidden="true" /></button></div></div><div className="replacement-stage-fields"><label>Find pattern<textarea aria-label={`Find pattern ${index + 1}`} aria-invalid={Boolean(patternError)} value={stage.find} onChange={(event) => updateStage(index, { ...stage, find: event.target.value })} rows={3} placeholder="e.g. \\s+$" />{patternError && <small className="regex-validation" role="status">{patternError}</small>}</label><label>Replace with<textarea aria-label={`Replacement text ${index + 1}`} value={stage.replace} onChange={(event) => updateStage(index, { ...stage, replace: parseMacrowhisperReplacement(event.target.value) })} rows={3} placeholder="Leave empty to remove matches" /><small>Use <code>{'${1}'}</code> for a capture group, or <code>{'${1::titleCase}'}</code> to transform it.</small></label></div></div>
      })}
    </div>
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
  open: boolean
  onToggle: (open: boolean) => void
}

function TriggerEditor({ action, selectedName, actionPath, drafts, valueFor, setDraftValue, commitIfChanged, commitField, revertField, retryField, resyncField, open, onToggle }: TriggerEditorProps) {
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
  return <div className="editor-section insert-disclosure-section settings-section"><Disclosure title="Triggers" subtitle="Match a phrase, app, mode, or URL." meta={summary} open={open} onToggle={onToggle} variant="defaults">
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
  const previewMode = useContext(PreviewModeContext)
  if (status === 'idle') return null
  return <span className={`field-state field-state-${status === 'saving' ? 'saving' : 'saved'}`}>{status === 'saving' ? (previewMode ? 'Updating preview…' : 'Saving…') : <><CheckIcon aria-hidden="true" /> {previewMode ? 'Updated in preview' : 'Saved'}</>}</span>
}

function OverrideField({ field, path, value, entry, meta, pending = false, onChoice, onText, onBlur, onRevert, onRetry, onResync, folderPickerPreview, chooseDirectory, disabled = false, disabledNote, utility }: { field: string; path: string[]; value: FieldValue; entry?: DraftEntry; meta: { label: string; description: string }; pending?: boolean; onChoice: (value: FieldValue) => void; onText: (value: string) => void; onBlur: (value: string) => void; onRevert: () => void; onRetry: () => void; onResync: () => void; folderPickerPreview: boolean; chooseDirectory?: (purpose: FolderPickerPurpose) => Promise<string | null>; disabled?: boolean; disabledNote?: string; utility?: ReactNode }) {
  const state = <FieldState entry={entry} onRevert={onRevert} onRetry={onRetry} onResync={onResync} errorId={fieldErrorId(path)} />
  const inputId = path.join('-')
  const numberField = field === 'actionDelay' || field === 'restoreClipboardDelay' || field === 'scriptWaitTimeout'
  const [numberOpen, setNumberOpen] = useState(value !== null && value !== undefined)
  let control: ReactNode = null

  if (field === 'icon' || field === 'moveTo') {
    control = <NullableTextControl kind={field} controlId={inputId} value={value} pending={pending} onChoice={onChoice} onText={onText} onBlur={onBlur} ariaLabel={meta.label} errorId={fieldErrorId(path)} revertKey={pathKey(path)} folderPickerPreview={folderPickerPreview} chooseDirectory={chooseDirectory} />
  } else if (numberField) {
    const showingValue = numberOpen || (value !== null && value !== undefined)
    control = <div className="override-control"><select id={inputId} aria-label={`${meta.label} mode`} value={pending && !showingValue ? 'pending' : 'value'} onChange={() => setNumberOpen(true)}>{pending && !showingValue && <option value="pending" disabled>Choose value…</option>}<option value="value">Custom</option></select>{showingValue && <input id={`${inputId}-value`} value={displayValue(value)} inputMode="decimal" onChange={(event) => onText(event.target.value)} onBlur={(event) => { if (!isFieldBlurActionTarget(event.relatedTarget, pathKey(path))) onBlur(event.target.value) }} aria-label={meta.label} aria-describedby={entry?.error ? fieldErrorId(path) : undefined} />}<span className="unit">seconds</span></div>
  } else if (booleanFields.has(field)) {
    const selected = value === true
    control = <div className="setting-input-stack"><select id={inputId} aria-label={meta.label} aria-describedby={entry?.error ? fieldErrorId(path) : undefined} value={pending ? 'pending' : selected ? 'on' : 'off'} onChange={(event) => onChoice(event.target.value === 'on')}>{pending && <option value="pending" disabled>Choose value…</option>}<option value="on">{booleanText(field, true)}</option><option value="off">{booleanText(field, false)}</option></select></div>
  }

  if (!control) return null
  return <div className="override-field"><div className="override-copy"><div className="override-label"><label htmlFor={inputId}>{meta.label}</label>{state}</div><p>{meta.description}</p></div><fieldset className="template-field override-setting" disabled={disabled}>{control}{disabledNote && <p className="template-note">{disabledNote}</p>}</fieldset>{utility}</div>
}

function Disclosure({ title, subtitle, meta, open, onToggle, children, variant = 'standard' }: { title: string; subtitle: string; meta?: ReactNode; open: boolean; onToggle: (open: boolean) => void; children: ReactNode; variant?: 'standard' | 'defaults' }) {
  return <details className={`disclosure ${variant === 'defaults' ? 'defaults-disclosure' : ''}`} open={open} onToggle={(event) => onToggle((event.currentTarget as HTMLDetailsElement).open)}><summary><span className="disclosure-heading"><strong>{title}</strong>{subtitle && <small>{subtitle}</small>}</span><span className="disclosure-summary-meta">{meta}</span><ChevronDownIcon aria-hidden="true" /></summary><div className="disclosure-body">{children}</div></details>
}

function UnsupportedActionGroup({ group, selectedName, snapshot, fixtureBacked }: { group: GroupDefinition; selectedName: string; snapshot: ConfigSnapshot; fixtureBacked: boolean }) {
  const count = Object.keys(snapshot[group.id]).length
  const selectedAction = selectedName ? snapshot[group.id][selectedName] : undefined
  const groupName = group.label === 'URLs' ? 'URL' : group.label
  const noun = `${groupName} ${count === 1 ? 'action' : 'actions'}`
  const title = selectedAction ? actionDisplayName(selectedName, selectedAction) : group.label
  return <div className="screen-content unsupported-screen"><div className="screen-intro"><div><h1>{title}</h1><p className="screen-description">{selectedAction ? `${group.shortLabel} action · ${group.description}` : group.description}</p></div><span className="coming-badge">{fixtureBacked ? 'Fixture scope' : 'Read-only for now'}</span></div><div className="unsupported-panel"><div className="unsupported-mark">{group.icon}</div><h2>{group.label} editing is next</h2><p>{fixtureBacked ? `The fixture includes ${count} ${noun} so cross-action links and names can be reviewed from Defaults and Insert controls.` : `This connected snapshot includes ${count} ${noun}. Cross-action links and names can be reviewed from Defaults and Insert controls while type-specific editing is prepared.`} Type-specific editors will reuse this transaction boundary.</p><div className="unsupported-grid"><div><strong>Selected action</strong><span>{selectedAction ? selectedName : 'Choose an action from the navigation rail.'}</span></div><div><strong>Preserved semantics</strong><span>{fixtureBacked ? 'Unsupported fields remain in the fixture payload and are not rewritten.' : 'Unsupported fields remain in the server snapshot and are not rewritten.'}</span></div></div></div></div>
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

function FolderChooserPreviewDialog({ label, onClose }: { label: string; onClose: () => void }) {
  const dialogRef = useRef<HTMLDialogElement>(null)
  const closeRef = useRef<HTMLButtonElement>(null)
  useModalBehavior(dialogRef, closeRef, onClose)
  return <div className="modal-backdrop" role="presentation"><dialog open ref={dialogRef} className="modal small-modal" aria-modal="true" aria-labelledby="folder-preview-title" aria-describedby="folder-preview-description"><div className="modal-icon neutral"><FolderIcon /></div><h2 id="folder-preview-title">Folder picker preview</h2><p id="folder-preview-description">This Vite preview cannot open the native macOS picker or return a usable path for the {label}. Type or paste the path for now. The connected editor uses this control through the daemon's native folder bridge.</p><div className="modal-actions"><button ref={closeRef} type="button" className="primary-button" onClick={onClose}>Continue typing</button></div></dialog></div>
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
