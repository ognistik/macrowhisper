import type {
  ActionConfig,
  ActionGroup,
  ConfigSnapshot,
  DefaultsConfig,
  InsertConfig,
  ScenarioDefinition,
  StoreScenario,
} from './model/types'

const defaultDefaults: DefaultsConfig = {
  watch: '~/superwhisper',
  disableUpdateCheck: false,
  muteNotifications: false,
  activeAction: 'autoPaste',
  icon: '',
  moveTo: '',
  simEsc: true,
  simKeypress: false,
  smartCasing: true,
  smartPunctuation: true,
  smartSpacing: true,
  actionDelay: 0,
  history: null,
  simReturn: false,
  returnDelay: 0.15,
  restoreClipboard: true,
  restoreClipboardDelay: 0.3,
  scheduledActionTimeout: 5,
  scriptAsync: true,
  scriptWaitTimeout: 3,
  clipboardStacking: false,
  clipboardAttachments: false,
  clipboardBuffer: 5,
  clipboardIgnore: '',
  bypassModes: '',
  muteTriggers: false,
  autoUpdateConfig: true,
  redactedLogs: true,
  nextAction: '',
}

const inheritedInsert: InsertConfig = {
  action: 'Capture this for my notes:\\n\\n{{swResult::ensureSentence}}',
  icon: null,
  moveTo: null,
  simEsc: null,
  simKeypress: null,
  smartCasing: null,
  smartPunctuation: null,
  smartSpacing: null,
  actionDelay: null,
  simReturn: null,
  restoreClipboard: null,
  restoreClipboardDelay: null,
  clipboardStacking: null,
  clipboardAttachments: null,
  inputCondition: null,
  nextAction: null,
  triggerVoice: 'note|capture note',
  triggerApps: null,
  triggerModes: 'writing|notes',
  triggerUrls: null,
  triggerLogic: null,
}

const customInsert: InsertConfig = {
  action: 'Reply with a concise answer:\\n\\n{{swResult}}',
  icon: '↗',
  moveTo: '',
  simEsc: false,
  simKeypress: true,
  smartCasing: false,
  smartPunctuation: true,
  smartSpacing: true,
  actionDelay: 0.08,
  simReturn: true,
  restoreClipboard: true,
  restoreClipboardDelay: 0.2,
  clipboardStacking: false,
  clipboardAttachments: false,
  inputCondition: 'simReturn|action',
  nextAction: '',
  triggerVoice: 'reply|*respond',
  triggerApps: 'Mail|Messages|com.apple.mail',
  triggerModes: null,
  triggerUrls: 'mail.example.test',
  triggerLogic: 'and',
}

const templateInsert: InsertConfig = {
  action: '.autoPaste',
  icon: '•',
  moveTo: null,
  simEsc: null,
  simKeypress: null,
  smartCasing: null,
  smartPunctuation: null,
  smartSpacing: null,
  actionDelay: null,
  simReturn: null,
  restoreClipboard: null,
  restoreClipboardDelay: null,
  clipboardStacking: null,
  clipboardAttachments: null,
  inputCondition: null,
  nextAction: null,
  triggerVoice: null,
  triggerApps: null,
  triggerModes: null,
  triggerUrls: null,
  triggerLogic: null,
}

const noneTemplate: InsertConfig = {
  action: '.none',
  icon: null,
  moveTo: null,
  simEsc: true,
  simKeypress: false,
  smartCasing: true,
  smartPunctuation: true,
  smartSpacing: true,
  actionDelay: 0.1,
  simReturn: true,
  restoreClipboard: true,
  restoreClipboardDelay: 0.3,
  clipboardStacking: true,
  clipboardAttachments: true,
  inputCondition: 'simReturn',
  nextAction: null,
  triggerVoice: 'skip|discard',
  triggerApps: null,
  triggerModes: null,
  triggerUrls: null,
  triggerLogic: null,
}

const invalidInsert: InsertConfig = {
  action: '{{swResult}}',
  icon: null,
  moveTo: null,
  simEsc: null,
  simKeypress: null,
  smartCasing: null,
  smartPunctuation: null,
  smartSpacing: null,
  actionDelay: null,
  simReturn: null,
  restoreClipboard: null,
  restoreClipboardDelay: null,
  clipboardStacking: null,
  clipboardAttachments: null,
  inputCondition: 'simReturn||action',
  nextAction: 'does-not-exist',
  triggerVoice: null,
  triggerApps: null,
  triggerModes: null,
  triggerUrls: null,
  triggerLogic: 'xor',
}

const sharedOtherActions = {
  urls: {
    search: { action: 'https://www.google.com/search?q={{swResult}}', triggerVoice: 'search|google', triggerLogic: 'or' } as ActionConfig,
  },
  shortcuts: {
    'Create task': { action: '{{swResult}}', triggerVoice: 'task', scriptAsync: null, scriptWaitTimeout: null, triggerLogic: 'or' } as ActionConfig,
  },
  scriptsShell: {
    copyResult: { action: "echo '{{swResult}}' | pbcopy", restoreClipboard: false, scriptAsync: true, triggerVoice: 'copy result', triggerLogic: 'or' } as ActionConfig,
  },
  scriptsAS: {
    notify: { action: 'display notification "{{swResult}}"', scriptAsync: true, triggerVoice: 'notify', triggerLogic: 'or' } as ActionConfig,
  },
}

export const scenarioDefinitions: ScenarioDefinition[] = [
  { id: 'populated', label: 'Populated', detail: 'A healthy config with inherited and custom Inserts.' },
  { id: 'invalid', label: 'Invalid field', detail: 'The file is readable, but one Insert has invalid condition and links.' },
  { id: 'conflict', label: 'Conflict', detail: 'A remote revision is waiting for the selected Insert.' },
  { id: 'empty', label: 'Empty Inserts', detail: 'No Insert actions exist yet.' },
  { id: 'disconnected', label: 'Disconnected', detail: 'The fixture API is offline. Drafts stay local.' },
]

function fingerprintFor(value: unknown): string {
  let hash = 2166136261
  const source = JSON.stringify(value)
  for (let index = 0; index < source.length; index += 1) {
    hash ^= source.charCodeAt(index)
    hash = Math.imul(hash, 16777619)
  }
  return `fixture-${(hash >>> 0).toString(16).padStart(8, '0')}`
}

function baseSnapshot(scenario: StoreScenario): ConfigSnapshot {
  const inserts: Record<string, InsertConfig> = {
    autoPaste: templateInsert,
    dailyNotes: inheritedInsert,
    quickReply: customInsert,
    skipOutside: noneTemplate,
  }
  if (scenario === 'invalid') inserts.brokenLink = invalidInsert
  const defaults = structuredClone(defaultDefaults)
  // The empty-list fixture represents a valid configuration with no fallback
  // action. Keeping autoPaste here would make the fixture self-invalid.
  if (scenario === 'empty') defaults.activeAction = ''
  const snapshotData = {
    defaults,
    inserts,
    ...sharedOtherActions,
  }
  // An empty action group is a valid configuration state. `empty` disk status
  // is reserved for a configuration file with no decodable contents, not a
  // healthy file whose Inserts dictionary happens to contain no actions.
  const disk = scenario === 'invalid'
    ? { status: 'invalid' as const, message: 'The JSON is readable, but semantic validation found an invalid Insert.' }
    : { status: 'valid' as const }
  const runtime = scenario === 'disconnected'
    ? { status: 'disconnected' as const, message: 'Fixture API disconnected. Changes remain in this browser tab.' }
    : scenario === 'invalid'
      ? { status: 'fallback' as const, message: 'Runtime is using fallback defaults while the file is invalid.' }
      : { status: 'connected' as const, message: 'Connected to the in-memory fixture adapter.' }

  return {
    revision: {
      generation: 'fixture-generation-01',
      version: 7,
      fingerprint: fingerprintFor(snapshotData),
    },
    schemaVersion: 3,
    path: '~/Library/Application Support/Superwhisper/macrowhisper.json',
    defaults,
    inserts: scenario === 'empty' ? {} : structuredClone(inserts),
    urls: structuredClone(sharedOtherActions.urls),
    shortcuts: structuredClone(sharedOtherActions.shortcuts),
    scriptsShell: structuredClone(sharedOtherActions.scriptsShell),
    scriptsAS: structuredClone(sharedOtherActions.scriptsAS),
    disk,
    runtime,
  }
}

export function createFixtureSnapshot(scenario: StoreScenario = 'populated'): ConfigSnapshot {
  return baseSnapshot(scenario)
}

export function getAllActionNames(snapshot: ConfigSnapshot): Array<{ name: string; group: ActionGroup }> {
  const groups: ActionGroup[] = ['inserts', 'urls', 'shortcuts', 'scriptsShell', 'scriptsAS']
  return groups.flatMap((group) => Object.keys(snapshot[group]).map((name) => ({ name, group })))
}

export function cloneFixtureSnapshot(snapshot: ConfigSnapshot): ConfigSnapshot {
  return structuredClone(snapshot)
}

export function nextFingerprint(snapshot: ConfigSnapshot): string {
  const { revision: _revision, ...data } = snapshot
  return fingerprintFor(data)
}
