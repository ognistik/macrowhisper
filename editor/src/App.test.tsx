import { act, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import App, { defaultFieldGroups, overrideFields } from './App'
import { defaultsSchema, insertSchema } from './generated/schema'
import { FixtureStore } from './store/fixtureStore'
import type { StoreScenario } from './model/types'
import type { EditorStore } from './model/types'

function installMediaQuery(matches: boolean) {
  const media = {
    matches,
    media: '(max-width: 780px)',
    onchange: null,
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
    addListener: vi.fn(),
    removeListener: vi.fn(),
    dispatchEvent: vi.fn(() => true),
  }
  Object.defineProperty(window, 'matchMedia', {
    configurable: true,
    value: vi.fn(() => media),
  })
  return media
}

function renderWithStore(scenario: StoreScenario = 'populated', writeDelayMs = 0) {
  const store = new FixtureStore(scenario, { writeDelayMs })
  render(<App store={store} />)
  return store
}

async function waitForSaved() {
  await waitFor(() => expect(screen.getAllByText('Updated in preview').length).toBeGreaterThan(0))
}

function liveLikeStore(): EditorStore {
  const fixture = new FixtureStore('populated', { writeDelayMs: 35 })
  return {
    getSnapshot: () => fixture.getSnapshot(),
    subscribe: (listener) => fixture.subscribe(listener),
    request: (edits) => fixture.request(edits),
    mutate: (request) => fixture.mutate(request),
    createInsert: (name, action) => fixture.createInsert(name, action),
    duplicateInsert: (sourceName, targetName) => fixture.duplicateInsert(sourceName, targetName),
    renameInsert: (sourceName, targetName) => fixture.renameInsert(sourceName, targetName),
    deleteInsert: (name) => fixture.deleteInsert(name),
  }
}

describe('configuration editor interactions', () => {
  beforeEach(() => {
    try {
      window.localStorage?.clear()
    } catch {
      // Node's jsdom runtime may omit localStorage unless a storage file is set.
    }
    installMediaQuery(false)
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('keeps rendered field metadata aligned with the generated schema', () => {
    const defaultControls = defaultFieldGroups.flatMap((section) => section.fields)
    const insertControls = [
      ...overrideFields,
      'action',
      'inputCondition',
      'nextAction',
      'triggerVoice',
      'triggerApps',
      'triggerModes',
      'triggerUrls',
      'triggerLogic',
    ]

    expect([...new Set([...defaultControls, 'noUpdates', 'noNoti'])].sort()).toEqual(Object.keys(defaultsSchema).sort())
    expect([...new Set(insertControls)].sort()).toEqual(Object.keys(insertSchema).sort())
  })

  it('presents one root default choice while preserving serialized field changes', async () => {
    const user = userEvent.setup()
    renderWithStore()

    const fallback = screen.getByRole('combobox', { name: 'Fallback action' })
    await user.click(fallback)
    const fallbackChoices = screen.getByRole('listbox', { name: 'Fallback action choices' })
    expect(within(fallbackChoices).getByRole('option', { name: /No fallback action/ })).toBeInTheDocument()
    expect(within(fallbackChoices).queryByRole('option', { name: /explicit/ })).not.toBeInTheDocument()
    expect(within(fallbackChoices).queryByRole('option', { name: 'Use built-in (autoPaste)' })).not.toBeInTheDocument()

    await user.click(within(fallbackChoices).getByRole('option', { name: /quickReply/ }))
    const notifications = screen.getByRole('combobox', { name: 'System notifications' })
    const updates = screen.getByRole('combobox', { name: 'Automatic update checks' })
    expect(updates.closest('.select-metadata-stack')).toHaveTextContent('Built-in')
    // Both writes start from the same visible revision. The editor queues the
    // second write against the first result instead of surfacing a stale error.
    await user.selectOptions(notifications, 'on')
    await user.selectOptions(updates, 'on')
    await waitFor(() => expect(screen.getAllByText('Updated in preview').length).toBeGreaterThanOrEqual(3))
    expect(fallback).toHaveTextContent('quickReply')
    expect(notifications).toHaveValue('on')
    expect(updates).toHaveValue('on')
    expect(within(updates).getByRole('option', { name: 'Allow checks' })).toBeInTheDocument()
    expect(updates.closest('.select-metadata-stack')).not.toHaveTextContent('Built-in')
  })

  it('separates built-in action choices from explicit values', async () => {
    const user = userEvent.setup()
    renderWithStore()

    const fallback = screen.getByRole('combobox', { name: 'Fallback action' })
    const updates = screen.getByRole('combobox', { name: 'Automatic update checks' })
    const moveRecording = screen.getByRole('combobox', { name: 'Move recording mode' })

    await user.click(fallback)
    const fallbackChoices = screen.getByRole('listbox', { name: 'Fallback action choices' })
    expect(within(fallbackChoices).getByRole('group', { name: 'Built-in value' })).toHaveTextContent('Auto-paste')
    expect(within(fallbackChoices).getByRole('group', { name: 'Actions' })).toHaveTextContent('No fallback action')
    expect(updates.querySelector('optgroup[label="Built-in value"] + hr + optgroup[label="Explicit values"]')).toBeInTheDocument()
    expect(moveRecording.querySelector('optgroup[label="Built-in value"] + hr + optgroup[label="Explicit values"]')).toBeInTheDocument()
  })

  it('browses Inserts without replacing Defaults, then opens a concrete Insert', async () => {
    const user = userEvent.setup()
    renderWithStore()

    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))

    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    const firstInsert = within(actionList).getByRole('option', { name: /autoPaste/ })
    const dailyNotes = within(actionList).getByRole('option', { name: /dailyNotes/ })
    expect(firstInsert).toHaveAttribute('aria-selected', 'false')
    expect(screen.getByRole('heading', { name: 'Defaults' })).toBeInTheDocument()
    expect(screen.queryByRole('heading', { name: 'autoPaste' })).not.toBeInTheDocument()

    firstInsert.focus()
    await user.keyboard('{ArrowDown}')
    expect(dailyNotes).toHaveFocus()
    expect(screen.getByRole('heading', { name: 'Defaults' })).toBeInTheDocument()
    await user.keyboard('{Enter}')
    expect(screen.getByRole('heading', { name: 'dailyNotes' })).toBeInTheDocument()
    const logic = screen.getByRole('combobox', { name: 'Trigger logic' })
    expect(within(logic).getByRole('option', { name: 'Use Defaults (Any OR)' })).toBeInTheDocument()
    expect(within(logic).getByRole('option', { name: 'Any (OR)' })).toBeInTheDocument()
    expect(within(logic).getByRole('option', { name: 'All (AND)' })).toBeInTheDocument()
    expect(within(logic).queryByRole('option', { name: /explicit empty/ })).not.toBeInTheDocument()
  })

  it('keeps the open editor while browsing another action group', async () => {
    const user = userEvent.setup()
    renderWithStore()

    const sections = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(sections).getByRole('button', { name: /^Inserts/ }))
    const inserts = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(inserts).getByRole('option', { name: /dailyNotes/ }))
    expect(screen.getByRole('heading', { name: 'dailyNotes' })).toBeInTheDocument()

    await user.click(within(inserts).getByRole('button', { name: 'All sections' }))
    await user.click(within(screen.getByRole('navigation', { name: 'Configuration sections' })).getByRole('button', { name: /^URLs/ }))
    const urls = screen.getByRole('navigation', { name: 'URL actions' })
    expect(within(urls).getByRole('option', { name: /search/ })).toHaveAttribute('aria-selected', 'false')
    expect(screen.getByRole('heading', { name: 'dailyNotes' })).toBeInTheDocument()

    await user.click(within(urls).getByRole('option', { name: /search/ }))
    expect(screen.getByRole('heading', { name: 'search' })).toBeInTheDocument()
    await user.click(within(urls).getByRole('button', { name: 'All sections' }))
    await user.click(within(screen.getByRole('navigation', { name: 'Configuration sections' })).getByRole('button', { name: 'Defaults' }))
    expect(screen.getByRole('heading', { name: 'Defaults' })).toBeInTheDocument()
  })

  it('treats an empty Inserts group as a healthy starting state', async () => {
    const user = userEvent.setup()
    renderWithStore('empty')
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })

    expect(screen.getByRole('button', { name: 'Preview mode' })).toBeInTheDocument()
    expect(screen.queryByText('Configuration file is empty')).not.toBeInTheDocument()
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))

    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    expect(within(actionList).getByText('No Inserts yet')).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Defaults' })).toBeInTheDocument()
    await user.click(within(actionList).getByRole('button', { name: 'New Insert' }))
    expect(within(actionList).getByRole('button', { name: 'Create Insert' })).toBeEnabled()
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })

  it('keeps Defaults calm until a section is opened', async () => {
    const user = userEvent.setup()
    renderWithStore()

    expect(screen.getByRole('heading', { name: 'Defaults' })).toBeInTheDocument()
    const insertionField = screen.getByRole('combobox', { name: 'Simulate Escape' })
    expect(insertionField.closest('details')).not.toHaveAttribute('open')
    await user.click(screen.getByText('Insertion', { selector: 'strong' }))
    expect(screen.getByRole('combobox', { name: 'Simulate Escape' })).toBeInTheDocument()
    expect(screen.getByText('Insertion', { selector: 'strong' }).closest('details')).toHaveAttribute('open')
    expect(screen.getByText('General behavior', { selector: 'strong' }).closest('details')).not.toHaveAttribute('open')
    expect(screen.queryByText(/settings ·/)).not.toBeInTheDocument()
  })

  it('chunks long Defaults sections and keeps inherited timing defaults available', async () => {
    const user = userEvent.setup()
    renderWithStore()

    await user.click(screen.getByText('Insertion', { selector: 'strong' }))
    expect(screen.getByRole('heading', { name: 'Before the action', level: 3 })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Text handling', level: 3 })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'After insertion', level: 3 })).toBeInTheDocument()
    expect(screen.getByRole('textbox', { name: 'Return delay' })).toBeInTheDocument()
    expect(screen.getByText('Default wait before pressing Return, including one-shot CLI auto-return.')).toBeInTheDocument()
    await user.selectOptions(screen.getByRole('combobox', { name: 'Press Return after insert' }), 'on')
    expect(screen.getByRole('textbox', { name: 'Return delay' })).toBeInTheDocument()
    await user.selectOptions(screen.getByRole('combobox', { name: 'Press Return after insert' }), 'off')
    expect(screen.getByRole('textbox', { name: 'Return delay' })).toBeInTheDocument()

    await user.click(screen.getByText('Clipboard', { selector: 'strong' }))
    expect(screen.getByRole('heading', { name: 'Capture and filter', level: 3 })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Clipboard context', level: 3 })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'After the action chain', level: 3 })).toBeInTheDocument()
    expect(screen.getByRole('textbox', { name: 'Clipboard restore delay' })).toBeInTheDocument()
    await user.selectOptions(screen.getByRole('combobox', { name: 'Restore clipboard' }), 'off')
    expect(screen.getByRole('textbox', { name: 'Clipboard restore delay' })).toBeInTheDocument()

    await user.click(screen.getByText('Scripts and triggers', { selector: 'strong' }))
    expect(screen.getByRole('heading', { name: 'Script execution', level: 3 })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Trigger matching', level: 3 })).toBeInTheDocument()
    expect(screen.getByRole('textbox', { name: 'Script wait timeout' })).toBeInTheDocument()
    await user.selectOptions(screen.getByRole('combobox', { name: 'Run scripts asynchronously' }), 'off')
    expect(screen.getByRole('textbox', { name: 'Script wait timeout' })).toBeInTheDocument()
    await user.selectOptions(screen.getByRole('combobox', { name: 'Run scripts asynchronously' }), 'on')
    expect(screen.getByRole('textbox', { name: 'Script wait timeout' })).toBeInTheDocument()
  })

  it('switches Defaults sections with one click and lets the current section close', async () => {
    const user = userEvent.setup()
    renderWithStore()

    const general = screen.getByText('General behavior', { selector: 'strong' }).closest('details')
    const insertionTitle = screen.getByText('Insertion', { selector: 'strong' })
    const insertion = insertionTitle.closest('details')

    expect(general).not.toHaveAttribute('open')
    await user.click(insertionTitle)
    expect(general).not.toHaveAttribute('open')
    expect(insertion).toHaveAttribute('open')
    await user.click(insertionTitle)
    expect(insertion).not.toHaveAttribute('open')
  })

  it('returns to a fully collapsed Defaults overview after navigation and remounting', async () => {
    const user = userEvent.setup()
    const store = new FixtureStore('populated')
    try {
      window.localStorage?.setItem('macrowhisper-editor-defaults-open-section', 'insertion')
    } catch {
      // This runtime may not provide localStorage; the editor must still start collapsed.
    }
    const first = render(<App store={store} />)
    const insertionTitle = screen.getByText('Insertion', { selector: 'strong' })
    expect(defaultFieldGroups.every((section) => !screen.getByText(section.label, { selector: 'strong' }).closest('details')?.hasAttribute('open'))).toBe(true)
    await user.click(insertionTitle)
    expect(insertionTitle.closest('details')).toHaveAttribute('open')

    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const inserts = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(inserts).getByRole('option', { name: /dailyNotes/ }))
    await user.click(within(inserts).getByRole('button', { name: 'All sections' }))
    await user.click(within(screen.getByRole('navigation', { name: 'Configuration sections' })).getByRole('button', { name: 'Defaults' }))
    expect(defaultFieldGroups.every((section) => !screen.getByText(section.label, { selector: 'strong' }).closest('details')?.hasAttribute('open'))).toBe(true)

    await user.click(screen.getByText('Insertion', { selector: 'strong' }))
    first.unmount()
    render(<App store={store} />)
    expect(defaultFieldGroups.every((section) => !screen.getByText(section.label, { selector: 'strong' }).closest('details')?.hasAttribute('open'))).toBe(true)
  })

  it('previews the Superwhisper folder chooser without changing the draft', async () => {
    const user = userEvent.setup()
    const store = renderWithStore()
    await user.click(screen.getByText('Recordings', { selector: 'strong' }))

    const watch = screen.getByRole('textbox', { name: 'Superwhisper folder' })
    const initial = store.getSnapshot().defaults.watch
    const mutate = vi.spyOn(store, 'mutate')
    const row = watch.closest('.setting-row') as HTMLElement
    await user.click(within(row).getByRole('button', { name: 'Choose Superwhisper folder' }))

    expect(screen.getByRole('dialog', { name: 'Folder picker preview' })).toBeInTheDocument()
    expect(store.getSnapshot().defaults.watch).toBe(initial)
    expect(mutate).not.toHaveBeenCalled()
    await user.keyboard('{Escape}')
    expect(screen.queryByRole('dialog', { name: 'Folder picker preview' })).not.toBeInTheDocument()

    await user.click(within(row).getByRole('button', { name: 'Choose Superwhisper folder' }))
    await user.click(screen.getByRole('button', { name: 'Continue typing' }))
    expect(screen.queryByRole('dialog', { name: 'Folder picker preview' })).not.toBeInTheDocument()
  })

  it('saves a folder returned by the live picker bridge', async () => {
    const user = userEvent.setup()
    const store = new FixtureStore('populated', { writeDelayMs: 0 })
    const chooseDirectory = vi.fn().mockResolvedValue('~/Documents/selected-superwhisper')
    Object.assign(store, { chooseDirectory })
    render(<App store={store} />)
    await user.click(screen.getByText('Recordings', { selector: 'strong' }))

    const watch = screen.getByRole('textbox', { name: 'Superwhisper folder' })
    const row = watch.closest('.setting-row') as HTMLElement
    await user.click(within(row).getByRole('button', { name: 'Choose Superwhisper folder' }))

    expect(chooseDirectory).toHaveBeenCalledWith('watch')
    await waitFor(() => expect(store.getSnapshot().defaults.watch).toBe('~/Documents/selected-superwhisper'))
    expect(watch).toHaveValue('~/Documents/selected-superwhisper')
    expect(screen.queryByRole('dialog', { name: 'Folder picker preview' })).not.toBeInTheDocument()
  })

  it('shows the clipboard app and bypass mode examples in their empty fields', async () => {
    const user = userEvent.setup()
    renderWithStore()
    await user.click(screen.getByText('Clipboard', { selector: 'strong' }))
    await user.click(screen.getByText('Scripts and triggers', { selector: 'strong' }))

    expect(screen.getByRole('textbox', { name: 'Ignore clipboard apps' })).toHaveAttribute('placeholder', 'Arc|Bitwarden|com.apple.passwords')
    expect(screen.getByRole('textbox', { name: 'Bypass modes' })).toHaveAttribute('placeholder', 'dictation|raw')
    expect(screen.getByText(/App names or bundle IDs to ignore/)).toBeInTheDocument()
    expect(screen.getByText(/Superwhisper modes to leave untouched/)).toBeInTheDocument()
  })

  it('reveals a recording path and chooser when Move recording is custom', async () => {
    const user = userEvent.setup()
    renderWithStore()
    await user.click(screen.getByText('Recordings', { selector: 'strong' }))

    const mode = screen.getByRole('combobox', { name: 'Move recording mode' })
    await user.selectOptions(mode, 'custom')
    const path = screen.getByRole('textbox', { name: 'Recording folder path' })
    const row = path.closest('.setting-row') as HTMLElement
    expect(within(row).getByRole('button', { name: 'Choose recording destination' })).toBeInTheDocument()
  })

  it('groups root actions by each field’s shipped built-in value', async () => {
    const user = userEvent.setup()
    renderWithStore()
    const active = screen.getByRole('combobox', { name: 'Fallback action' })
    const next = screen.getByRole('combobox', { name: 'Default next action' })
    await user.click(active)
    const activeChoices = screen.getByRole('listbox', { name: 'Fallback action choices' })
    expect(within(activeChoices).getByRole('group', { name: 'Built-in value' })).toHaveTextContent('Auto-paste')
    expect(within(activeChoices).getByRole('group', { name: 'Actions' })).toHaveTextContent('Do nothing')
    await user.keyboard('{Escape}')
    await user.click(next)
    const nextChoices = screen.getByRole('listbox', { name: 'Default next action choices' })
    expect(within(nextChoices).getByRole('group', { name: 'Built-in value' })).toHaveTextContent('No next action')
    expect(within(nextChoices).getByRole('group', { name: 'Actions' })).toHaveTextContent('Auto-paste')
    expect(active.closest('.select-control-wrapper')).toHaveTextContent('Built-in')
    expect(next.closest('.select-control-wrapper')).toHaveTextContent('Built-in')
    expect(active).toHaveAccessibleDescription('Built-in')
    expect(next).toHaveAccessibleDescription('Built-in')
  })

  it('filters action choices and selects the active result from the keyboard', async () => {
    const user = userEvent.setup()
    const store = renderWithStore()
    await user.click(screen.getByRole('combobox', { name: 'Fallback action' }))
    const searchActions = screen.getByRole('searchbox', { name: 'Search fallback action' })
    await user.type(searchActions, 'notify')
    const choices = screen.getByRole('listbox', { name: 'Fallback action choices' })
    expect(within(choices).getAllByRole('option')).toHaveLength(1)
    expect(within(choices).getByRole('option', { name: /notify/ })).toBeInTheDocument()
    await user.keyboard('{Enter}')
    await waitFor(() => expect(store.getSnapshot().defaults.activeAction).toBe('notify'))
    expect(screen.getByRole('combobox', { name: 'Fallback action' })).toHaveTextContent('notify')
  })

  it('closes an action picker with Escape and returns focus to its trigger', async () => {
    const user = userEvent.setup()
    renderWithStore()
    const fallback = screen.getByRole('combobox', { name: 'Fallback action' })
    await user.click(fallback)
    await waitFor(() => expect(screen.getByRole('searchbox', { name: 'Search fallback action' })).toHaveFocus())
    await user.keyboard('{Escape}')
    expect(screen.queryByRole('listbox', { name: 'Fallback action choices' })).not.toBeInTheDocument()
    expect(fallback).toHaveFocus()
  })

  it('preserves inheritance and stop-chain sentinels in the searchable action picker', async () => {
    const user = userEvent.setup()
    const store = renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /dailyNotes/ }))
    await user.click(screen.getByText('Chaining', { selector: 'strong' }))

    const nextAction = screen.getByRole('combobox', { name: 'Next action' })
    await user.click(nextAction)
    let choices = screen.getByRole('listbox', { name: 'Next action choices' })
    expect(within(choices).getByRole('option', { name: /Use Defaults next action/ })).toBeInTheDocument()
    expect(within(choices).getByRole('option', { name: /Stop chain/ })).toBeInTheDocument()
    expect(within(choices).queryByRole('option', { name: /dailyNotes/ })).not.toBeInTheDocument()
    await user.click(within(choices).getByRole('option', { name: /Stop chain/ }))
    await waitFor(() => expect(store.getSnapshot().inserts.dailyNotes.nextAction).toBe(''))

    await user.click(nextAction)
    choices = screen.getByRole('listbox', { name: 'Next action choices' })
    await user.click(within(choices).getByRole('option', { name: /Use Defaults next action/ }))
    await waitFor(() => expect(store.getSnapshot().inserts.dailyNotes.nextAction).toBeNull())
  })

  it('labels the fixture as an in-memory preview instead of a connected configuration', async () => {
    const user = userEvent.setup()
    renderWithStore()
    expect(screen.getByRole('note')).toHaveTextContent('Preview mode')
    expect(screen.getByRole('note')).toHaveTextContent('They do not write macrowhisper.json')
    expect(screen.queryByRole('dialog', { name: 'Editor details' })).not.toBeInTheDocument()
    expect(screen.queryByText('Revision 7')).not.toBeInTheDocument()
    expect(screen.queryByText('CONFIG VERSION')).not.toBeInTheDocument()
    expect(screen.queryByText('WATCH FOLDER')).not.toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Preview mode' }))
    const details = screen.getByRole('dialog', { name: 'Editor details' })
    expect(within(details).getByText('Changes stay in this browser tab and reset when the preview reloads. macrowhisper.json is not changed.')).toBeInTheDocument()
    expect(within(details).getByText('Preview storage')).toBeInTheDocument()
    expect(within(details).getByText('In-memory sample data')).toBeInTheDocument()
    expect(within(details).getByText('Reloading resets these sample values. No configuration file is read or written.')).toBeInTheDocument()
    expect(within(details).queryByRole('button', { name: 'Close editor details' })).not.toBeInTheDocument()
    expect(within(details).queryByRole('button', { name: 'Copy diagnostics' })).not.toBeInTheDocument()
    expect(within(details).queryByRole('button', { name: 'Copy path' })).not.toBeInTheDocument()
    expect(within(details).queryByRole('button', { name: 'Reveal' })).not.toBeInTheDocument()
    expect(within(details).getByRole('radiogroup', { name: 'Appearance' })).toBeInTheDocument()
    expect(within(details).queryByText('Technical details')).not.toBeInTheDocument()
    await user.keyboard('{Escape}')
    expect(screen.queryByRole('dialog', { name: 'Editor details' })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Preview mode' })).toHaveFocus()
  })

  it('preserves canonical Connected and Saved labels for a live store', async () => {
    const user = userEvent.setup()
    render(<App store={liveLikeStore()} />)

    expect(screen.getByRole('button', { name: 'Connected' })).toBeInTheDocument()
    expect(screen.queryByRole('note')).not.toBeInTheDocument()
    await user.selectOptions(screen.getByRole('combobox', { name: 'Simulate Escape' }), 'off')
    await waitFor(() => expect(screen.getAllByText('Saving…').length).toBeGreaterThan(0))
    await waitFor(() => expect(screen.getAllByText('Saved').length).toBeGreaterThan(0))
  })

  it('blocks legacy editing behind an accessible v3 migration banner', async () => {
    const user = userEvent.setup()
    const live = liveLikeStore()
    const current = live.getSnapshot()
    const migrated = { ...current, schemaVersion: 3, isLegacy: false, readOnly: undefined }
    const updateConfiguration = vi.fn().mockResolvedValue(migrated)
    const legacy = {
      ...live,
      getSnapshot: () => ({
        ...current,
        isLegacy: true,
        readOnly: [{ path: [], reason: 'This legacy configuration must be migrated before it can be edited here.' }],
      }),
      updateConfiguration,
    } as EditorStore
    render(<App store={legacy} />)

    const banner = screen.getByRole('alert', { name: 'Update required before editing' })
    expect(banner).toHaveTextContent('compatibility mode')
    expect(banner).toHaveTextContent('backup')
    expect(banner).toHaveTextContent('version 3')
    expect(screen.getByRole('button', { name: 'Update required' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Update to version 3' })).toBeEnabled()
    await user.click(within(screen.getByRole('navigation', { name: 'Configuration sections' })).getByRole('button', { name: /^Inserts/ }))
    await user.click(within(screen.getByRole('navigation', { name: 'Insert actions' })).getByRole('option', { name: /dailyNotes/ }))
    expect(screen.getByRole('button', { name: 'Rename' })).toBeDisabled()

    await user.click(screen.getByRole('button', { name: 'Update to version 3' }))
    await waitFor(() => expect(updateConfiguration).toHaveBeenCalledTimes(1))
    await waitFor(() => expect(screen.queryByRole('alert', { name: 'Update required before editing' })).not.toBeInTheDocument())
    expect(screen.getByRole('button', { name: 'Connected' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Rename' })).toBeEnabled()
  })

  it('keeps legacy editing blocked and explains a failed explicit migration', async () => {
    const user = userEvent.setup()
    const live = liveLikeStore()
    const current = live.getSnapshot()
    const updateConfiguration = vi.fn().mockRejectedValue(new Error('Migration failed.'))
    const legacy = {
      ...live,
      getSnapshot: () => ({
        ...current,
        isLegacy: true,
        readOnly: [{ path: [], reason: 'This legacy configuration must be migrated before it can be edited here.' }],
      }),
      updateConfiguration,
    } as EditorStore
    render(<App store={legacy} />)

    await user.click(within(screen.getByRole('navigation', { name: 'Configuration sections' })).getByRole('button', { name: /^Inserts/ }))
    await user.click(within(screen.getByRole('navigation', { name: 'Insert actions' })).getByRole('option', { name: /dailyNotes/ }))
    expect(screen.getByRole('button', { name: 'Rename' })).toBeDisabled()
    await user.click(screen.getByRole('button', { name: 'Update to version 3' }))
    await waitFor(() => expect(updateConfiguration).toHaveBeenCalledTimes(1))
    expect(screen.getByText('Migration failed.')).toBeInTheDocument()
    expect(screen.getByRole('alert', { name: 'Update required before editing' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Rename' })).toBeDisabled()
  })

  it('reveals status context and diagnostics only when the editor needs attention', async () => {
    const user = userEvent.setup()
    renderWithStore('invalid')

    await user.click(screen.getByRole('button', { name: 'Runtime fallback' }))
    const details = screen.getByRole('dialog', { name: 'Editor details' })
    expect(within(details).getByText('Runtime is using fallback defaults while the file is invalid.')).toBeInTheDocument()
    expect(within(details).getByRole('button', { name: 'Copy diagnostics' })).toBeInTheDocument()
    expect(within(details).queryByText('Technical details')).not.toBeInTheDocument()
  })

  it('shows the History retention unit beside its numeric field', async () => {
    const user = userEvent.setup()
    renderWithStore()
    await user.click(screen.getByText('Recordings', { selector: 'strong' }))
    const history = screen.getByRole('textbox', { name: 'History retention' })
    expect(history.closest('.input-with-unit')).toHaveTextContent('days')
    expect(history).toHaveAttribute('placeholder', 'Keep forever')
  })

  it('shows configured action state first and adds exceptions on demand', async () => {
    const user = userEvent.setup()
    const store = renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    expect(within(actionList).queryByRole('button', { name: 'Duplicate' })).not.toBeInTheDocument()
    await user.click(within(actionList).getByRole('option', { name: /dailyNotes/ }))

    await user.click(screen.getByText('Action overrides', { selector: 'strong' }))
    const insertion = screen.getByText('Action overrides', { selector: 'strong' }).closest('details')
    expect(insertion).not.toBeNull()
    expect(screen.queryByText('Insertion behavior', { selector: 'strong' })).not.toBeInTheDocument()
    expect(within(insertion!).getByText('Using Defaults')).toBeInTheDocument()
    expect(screen.queryByRole('combobox', { name: 'Simulate Escape' })).not.toBeInTheDocument()
    const emptyAddOverride = within(insertion!).getByRole('combobox', { name: 'Add override' })
    expect(emptyAddOverride.closest('.insertion-empty-state')).not.toBeNull()

    await user.selectOptions(emptyAddOverride, 'simEsc')
    const escapeControl = within(insertion!).getByRole('combobox', { name: 'Simulate Escape' })
    expect(escapeControl).toHaveValue('pending')
    expect(within(escapeControl).getByRole('option', { name: 'Choose value…' })).toBeDisabled()
    expect(within(escapeControl).getByRole('option', { name: 'Simulate Escape (current Default)' })).toBeInTheDocument()
    expect(within(escapeControl).getByRole('option', { name: 'Skip Escape' })).toBeInTheDocument()
    const cancelOverride = within(insertion!).getByRole('button', { name: 'Cancel adding Simulate Escape override' })
    expect(cancelOverride).not.toHaveAttribute('title')
    expect(cancelOverride).toHaveTextContent('')
    await user.selectOptions(escapeControl, 'off')
    const removeOverride = await within(insertion!).findByRole('button', { name: 'Remove Simulate Escape override' })
    expect(removeOverride).not.toHaveAttribute('title')
    expect(removeOverride).toHaveTextContent('')

    await user.click(removeOverride)
    await waitFor(() => expect(within(insertion!).getByText('Using Defaults')).toBeInTheDocument())
    expect(within(insertion!).queryByText(/Removing an override/)).not.toBeInTheDocument()
    const addAgain = within(insertion!).getByRole('combobox', { name: 'Add override' })
    expect(addAgain).toBeInTheDocument()

    await user.selectOptions(addAgain, 'simEsc')
    await user.selectOptions(within(insertion!).getByRole('combobox', { name: 'Simulate Escape' }), 'on')
    expect(await within(insertion!).findByRole('button', { name: 'Remove Simulate Escape override' })).toBeInTheDocument()
    await waitFor(() => expect(store.getSnapshot().inserts.dailyNotes.simEsc).toBe(true))
  })

  it('keeps newly added overrides in place until the section closes, then restores alphabetical order', async () => {
    const user = userEvent.setup()
    renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /dailyNotes/ }))
    const actionOverrides = screen.getByText('Action overrides', { selector: 'strong' })
    await user.click(actionOverrides)
    const insertion = actionOverrides.closest('details')
    expect(insertion).not.toBeNull()

    const addOverride = within(insertion!).getByRole('combobox', { name: 'Add override' })
    const menuLabels = within(addOverride).getAllByRole('option').slice(1).map((option) => option.textContent)
    expect(menuLabels).toEqual([
      'Action delay',
      'Clipboard attachments',
      'Clipboard restore delay',
      'Icon',
      'Move recording',
      'Press Return after insert',
      'Restore clipboard',
      'Simulate Escape',
      'Smart casing',
      'Smart punctuation',
      'Smart spacing',
      'Stack clipboard context',
      'Type instead of paste',
    ])

    const visibleLabels = () => Array.from(insertion!.querySelectorAll('.override-label label')).map((label) => label.textContent)
    await user.selectOptions(addOverride, 'simEsc')
    await user.selectOptions(within(insertion!).getByRole('combobox', { name: 'Add override' }), 'actionDelay')
    expect(visibleLabels()).toEqual(['Simulate Escape', 'Action delay'])
    await user.selectOptions(within(insertion!).getByRole('combobox', { name: 'Action delay mode' }), 'custom')
    await waitFor(() => expect(visibleLabels()).toEqual(['Simulate Escape', 'Action delay']))
    await user.selectOptions(within(insertion!).getByRole('combobox', { name: 'Simulate Escape' }), 'off')
    await waitFor(() => expect(visibleLabels()).toEqual(['Simulate Escape', 'Action delay']))

    await user.click(actionOverrides)
    await user.click(actionOverrides)
    await waitFor(() => expect(visibleLabels()).toEqual(['Action delay', 'Simulate Escape']))

    const actionDelay = within(insertion!).getByRole('textbox', { name: 'Action delay' })
    await user.clear(actionDelay)
    await user.type(actionDelay, '0.2')
    await user.tab()
    await waitFor(() => expect(visibleLabels()).toEqual(['Action delay', 'Simulate Escape']))
  })

  it('does not persist an override row until the user chooses a value', async () => {
    const user = userEvent.setup()
    const store = new FixtureStore('populated', { writeDelayMs: 0 })
    const mutate = vi.spyOn(store, 'mutate')
    const mounted = render(<App store={store} />)
    const openDailyNotesOverrides = async () => {
      const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
      await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
      const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
      await user.click(within(actionList).getByRole('option', { name: /dailyNotes/ }))
      const actionOverrides = screen.getByText('Action overrides', { selector: 'strong' })
      await user.click(actionOverrides)
      return actionOverrides.closest('details') as HTMLDetailsElement
    }

    let insertion = await openDailyNotesOverrides()
    await user.selectOptions(within(insertion).getByRole('combobox', { name: 'Add override' }), 'clipboardAttachments')
    expect(within(insertion).getByRole('combobox', { name: 'Clipboard attachments' })).toHaveValue('pending')
    expect(store.getSnapshot().inserts.dailyNotes.clipboardAttachments).toBeNull()

    await user.click(screen.getByText('Action overrides', { selector: 'strong' }))
    await user.click(screen.getByText('Action overrides', { selector: 'strong' }))
    expect(within(insertion).queryByRole('combobox', { name: 'Clipboard attachments' })).not.toBeInTheDocument()
    expect(mutate).not.toHaveBeenCalled()

    await user.selectOptions(within(insertion).getByRole('combobox', { name: 'Add override' }), 'clipboardAttachments')
    expect(within(insertion).getByRole('combobox', { name: 'Clipboard attachments' })).toHaveValue('pending')

    await user.click(screen.getByText('Conditions', { selector: 'strong' }))
    await user.click(screen.getByText('Action overrides', { selector: 'strong' }))
    expect(within(insertion).queryByRole('combobox', { name: 'Clipboard attachments' })).not.toBeInTheDocument()

    await user.selectOptions(within(insertion).getByRole('combobox', { name: 'Add override' }), 'clipboardAttachments')
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /quickReply/ }))
    await user.click(within(actionList).getByRole('option', { name: /dailyNotes/ }))
    await user.click(screen.getByText('Action overrides', { selector: 'strong' }))
    insertion = screen.getByText('Action overrides', { selector: 'strong' }).closest('details') as HTMLDetailsElement
    expect(within(insertion).queryByRole('combobox', { name: 'Clipboard attachments' })).not.toBeInTheDocument()

    await user.selectOptions(within(insertion).getByRole('combobox', { name: 'Add override' }), 'clipboardAttachments')

    mounted.unmount()
    render(<App store={store} />)
    insertion = await openDailyNotesOverrides()
    expect(within(insertion).queryByRole('combobox', { name: 'Clipboard attachments' })).not.toBeInTheDocument()
    expect(store.getSnapshot().inserts.dailyNotes.clipboardAttachments).toBeNull()
  })

  it('keeps custom icon controls together in an insertion override row', async () => {
    const user = userEvent.setup()
    renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /dailyNotes/ }))

    await user.click(screen.getByText('Action overrides', { selector: 'strong' }))
    const insertion = screen.getByText('Action overrides', { selector: 'strong' }).closest('details')
    expect(insertion).not.toBeNull()
    await user.selectOptions(within(insertion!).getByRole('combobox', { name: 'Add override' }), 'icon')
    const iconMode = within(insertion!).getByRole('combobox', { name: 'Icon mode' })
    expect(iconMode).toHaveValue('pending')
    expect(within(iconMode).getByRole('option', { name: 'Choose value…' })).toBeDisabled()
    expect(within(iconMode).getByRole('option', { name: 'No icon (current Default)' })).toBeInTheDocument()
    await user.selectOptions(iconMode, 'custom')

    const customIcon = within(insertion!).getByRole('textbox', { name: 'Custom icon' })
    expect(customIcon.closest('.nullable-control-icon')).not.toBeNull()
    expect(within(insertion!).getByRole('button', { name: 'Cancel adding Icon override' })).toBeInTheDocument()
  })

  it('pins and prefills custom inherited icon and recording values', async () => {
    const user = userEvent.setup()
    const store = new FixtureStore('populated', { writeDelayMs: 0 })
    store.externalChange((snapshot) => {
      snapshot.defaults.icon = '★'
      snapshot.defaults.moveTo = '~/Documents/processed-recordings'
    })
    render(<App store={store} />)

    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /dailyNotes/ }))
    await user.click(screen.getByText('Action overrides', { selector: 'strong' }))
    const insertion = screen.getByText('Action overrides', { selector: 'strong' }).closest('details')
    expect(insertion).not.toBeNull()

    await user.selectOptions(within(insertion!).getByRole('combobox', { name: 'Add override' }), 'icon')
    const iconMode = within(insertion!).getByRole('combobox', { name: 'Icon mode' })
    expect(within(iconMode).getByRole('option', { name: 'Custom (current Default)' })).toBeInTheDocument()
    await user.selectOptions(iconMode, 'custom')
    expect(within(insertion!).getByRole('textbox', { name: 'Custom icon' })).toHaveValue('★')
    await waitFor(() => expect(store.getSnapshot().inserts.dailyNotes.icon).toBe('★'))

    await user.selectOptions(within(insertion!).getByRole('combobox', { name: 'Add override' }), 'moveTo')
    const moveMode = within(insertion!).getByRole('combobox', { name: 'Move recording mode' })
    expect(within(moveMode).getByRole('option', { name: 'Custom (current Default)' })).toBeInTheDocument()
    await user.selectOptions(moveMode, 'custom')
    expect(within(insertion!).getByRole('textbox', { name: 'Recording folder path' })).toHaveValue('~/Documents/processed-recordings')
    await waitFor(() => expect(store.getSnapshot().inserts.dailyNotes.moveTo).toBe('~/Documents/processed-recordings'))
  })

  it('offers the inherited numeric value as an explicit override and a Custom starting point', async () => {
    const user = userEvent.setup()
    const store = renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /dailyNotes/ }))
    await user.click(screen.getByText('Action overrides', { selector: 'strong' }))
    const insertion = screen.getByText('Action overrides', { selector: 'strong' }).closest('details')
    expect(insertion).not.toBeNull()

    await user.selectOptions(within(insertion!).getByRole('combobox', { name: 'Add override' }), 'actionDelay')
    let delayMode = within(insertion!).getByRole('combobox', { name: 'Action delay mode' })
    expect(within(delayMode).getByRole('option', { name: '0 seconds (current Default)' })).toBeInTheDocument()
    await user.selectOptions(delayMode, within(delayMode).getByRole('option', { name: '0 seconds (current Default)' }))
    await waitFor(() => expect(store.getSnapshot().inserts.dailyNotes.actionDelay).toBe(0))
    expect(delayMode).toHaveValue('custom')
    expect(within(insertion!).getByRole('textbox', { name: 'Action delay' })).toHaveValue('0')

    act(() => {
      store.externalChange((snapshot) => { snapshot.defaults.actionDelay = 0.25 })
    })
    await waitFor(() => expect(within(delayMode).getByRole('option', { name: '0.25 seconds (current Default)' })).toBeInTheDocument())
    expect(delayMode).toHaveValue('custom')
    expect(within(insertion!).getByRole('textbox', { name: 'Action delay' })).toHaveValue('0')
    expect(store.getSnapshot().inserts.dailyNotes.actionDelay).toBe(0)

    await user.click(within(insertion!).getByRole('button', { name: 'Remove Action delay override' }))
    await waitFor(() => expect(store.getSnapshot().inserts.dailyNotes.actionDelay).toBeNull())
    await user.selectOptions(within(insertion!).getByRole('combobox', { name: 'Add override' }), 'actionDelay')
    delayMode = within(insertion!).getByRole('combobox', { name: 'Action delay mode' })
    await user.selectOptions(delayMode, 'custom')
    expect(delayMode).toHaveValue('custom')
    expect(within(insertion!).getByRole('textbox', { name: 'Action delay' })).toHaveValue('0.25')
    await waitFor(() => expect(store.getSnapshot().inserts.dailyNotes.actionDelay).toBe(0.25))
  })

  it('keeps invalid numeric overrides contained beside their editor with useful guidance', async () => {
    const user = userEvent.setup()
    const store = renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /dailyNotes/ }))
    await user.click(screen.getByText('Action overrides', { selector: 'strong' }))
    const insertion = screen.getByText('Action overrides', { selector: 'strong' }).closest('details')
    expect(insertion).not.toBeNull()

    await user.selectOptions(within(insertion!).getByRole('combobox', { name: 'Add override' }), 'restoreClipboardDelay')
    await user.selectOptions(within(insertion!).getByRole('combobox', { name: 'Clipboard restore delay mode' }), 'custom')
    const input = within(insertion!).getByRole('textbox', { name: 'Clipboard restore delay' })
    await waitFor(() => expect(store.getSnapshot().inserts.dailyNotes.restoreClipboardDelay).toBe(0.3))
    await user.clear(input)
    await user.type(input, '2d')
    fireEvent.blur(input)

    const guidance = await within(insertion!).findByText('Enter a valid number.')
    const row = input.closest('.override-field') as HTMLElement
    expect(guidance.closest('.override-setting')).not.toBeNull()
    expect(within(row.querySelector('.override-status') as HTMLElement).getByText('Preview not updated')).toBeInTheDocument()
    expect(row.querySelector('.override-copy')?.contains(row.querySelector('.override-status'))).toBe(false)
    expect(within(row).queryByRole('button', { name: 'Retry' })).not.toBeInTheDocument()
    expect(screen.queryByText('A set edit needs a JSON value.')).not.toBeInTheDocument()
    expect(store.getSnapshot().inserts.dailyNotes.restoreClipboardDelay).toBe(0.3)
  })

  it('keeps an empty Conditions section visual and commits only after a context is chosen', async () => {
    const user = userEvent.setup()
    const store = renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /dailyNotes/ }))

    const conditionsHeading = screen.getByText('Conditions', { selector: 'strong' })
    await user.click(conditionsHeading)
    const conditions = conditionsHeading.closest('details') as HTMLDetailsElement
    expect(within(conditions).queryByText('No conditional behavior is configured.')).not.toBeInTheDocument()
    expect(within(conditions).queryByText('Generated expression')).not.toBeInTheDocument()
    expect(within(conditions).queryByRole('textbox', { name: 'Advanced input condition' })).not.toBeInTheDocument()
    expect(within(conditions).getByText('Same behavior everywhere')).toBeInTheDocument()

    let addCondition = within(conditions).getByRole('combobox', { name: 'Add condition' })
    expect(within(addCondition).getAllByRole('option').map((option) => option.textContent)).toEqual(['Add condition…', 'Payload'])
    await user.selectOptions(addCondition, 'action')
    const payloadCondition = within(conditions).getByRole('combobox', { name: 'Condition for action' })
    expect(payloadCondition).toHaveValue('')
    expect(within(conditions).getByText('Choose where this payload should run.')).toBeInTheDocument()
    expect(within(payloadCondition).getByRole('option', { name: 'Choose where…' })).toBeInTheDocument()
    expect(store.getSnapshot().inserts.dailyNotes.inputCondition).toBeNull()
    expect(within(conditions).getByRole('button', { name: 'Cancel adding Payload condition' })).toBeInTheDocument()

    await user.click(within(conditions).getByRole('button', { name: 'Cancel adding Payload condition' }))
    expect(within(conditions).queryByRole('combobox', { name: 'Condition for action' })).not.toBeInTheDocument()
    addCondition = within(conditions).getByRole('combobox', { name: 'Add condition' })
    await user.selectOptions(addCondition, 'action')
    await user.selectOptions(within(conditions).getByRole('combobox', { name: 'Condition for action' }), 'inside')
    await waitFor(() => expect(store.getSnapshot().inserts.dailyNotes.inputCondition).toBe('action'))
    expect(within(conditions).getByText('Runs in text fields. Skipped outside.')).toBeInTheDocument()

    await user.click(within(conditions).getByRole('button', { name: 'Remove Payload condition' }))
    await waitFor(() => expect(store.getSnapshot().inserts.dailyNotes.inputCondition).toBe(''))
    expect(within(conditions).queryByRole('combobox', { name: 'Condition for action' })).not.toBeInTheDocument()
  })

  it('offers conditions only for Payload and explicitly configured eligible settings', async () => {
    const user = userEvent.setup()
    renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /quickReply/ }))
    const conditionsHeading = screen.getByText('Conditions', { selector: 'strong' })
    await user.click(conditionsHeading)
    const conditions = conditionsHeading.closest('details') as HTMLDetailsElement

    expect(within(conditions).getByText('Payload')).toBeInTheDocument()
    expect(within(conditions).getByText('Press Return after insert')).toBeInTheDocument()
    expect(within(conditions).getByText('Runs in text fields. Skipped outside.')).toBeInTheDocument()
    expect(within(conditions).getByText('Applies in text fields. Uses Defaults outside.')).toBeInTheDocument()
    const addCondition = within(conditions).getByRole('combobox', { name: 'Add condition' })
    expect(within(addCondition).getAllByRole('option').slice(1).map((option) => option.textContent)).toEqual([
      'Action delay',
      'Clipboard restore delay',
      'Move recording',
      'Next action',
      'Restore clipboard',
      'Simulate Escape',
    ])
    expect(within(addCondition).queryByRole('option', { name: 'Stack clipboard context' })).not.toBeInTheDocument()
    expect(within(addCondition).queryByRole('option', { name: 'Type instead of paste' })).not.toBeInTheDocument()
  })

  it('preserves inert saved conditions and routes users to configure their target', async () => {
    const user = userEvent.setup()
    const store = new FixtureStore('populated', { writeDelayMs: 0 })
    store.externalChange((snapshot) => { snapshot.inserts.dailyNotes.inputCondition = 'simReturn' })
    render(<App store={store} />)
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /dailyNotes/ }))
    const conditionsHeading = screen.getByText('Conditions', { selector: 'strong' })
    await user.click(conditionsHeading)
    const conditions = conditionsHeading.closest('details') as HTMLDetailsElement

    expect(within(conditions).getByText('No effect until Press Return after insert has an action override.')).toBeInTheDocument()
    expect(within(conditions).getByRole('combobox', { name: 'Condition for simReturn' })).toBeDisabled()
    await user.click(within(conditions).getByRole('button', { name: 'Add override' }))

    const actionOverridesHeading = screen.getByText('Action overrides', { selector: 'strong' })
    const actionOverrides = actionOverridesHeading.closest('details') as HTMLDetailsElement
    expect(actionOverrides).toHaveAttribute('open')
    expect(within(actionOverrides).getByRole('combobox', { name: 'Press Return after insert' })).toHaveValue('pending')
    expect(store.getSnapshot().inserts.dailyNotes.inputCondition).toBe('simReturn')
  })

  it('keeps unusual manual expressions exact until deliberate visual recovery', async () => {
    const user = userEvent.setup()
    const store = new FixtureStore('populated', { writeDelayMs: 0 })
    const unusual = 'simReturn|!simReturn|action'
    store.externalChange((snapshot) => { snapshot.inserts.quickReply.inputCondition = unusual })
    render(<App store={store} />)
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /quickReply/ }))
    const conditionsHeading = screen.getByText('Conditions', { selector: 'strong' })
    await user.click(conditionsHeading)
    const conditions = conditionsHeading.closest('details') as HTMLDetailsElement

    expect(within(conditions).getByRole('group', { name: 'These conditions need review' })).toHaveTextContent(unusual)
    expect(store.getSnapshot().inserts.quickReply.inputCondition).toBe(unusual)
    expect(within(conditions).queryByRole('combobox', { name: 'Add condition' })).not.toBeInTheDocument()
    expect(within(conditions).queryByRole('textbox', { name: 'Advanced input condition' })).not.toBeInTheDocument()

    await user.click(within(conditions).getByRole('button', { name: 'Replace with visual conditions' }))
    await waitFor(() => expect(store.getSnapshot().inserts.quickReply.inputCondition).toBe('action|!simReturn'))
    expect(within(conditions).getByRole('combobox', { name: 'Condition for action' })).toHaveValue('inside')
    expect(within(conditions).getByRole('combobox', { name: 'Condition for simReturn' })).toHaveValue('outside')
  })

  it('retains Custom text conditions behind built-in payload behavior', async () => {
    const user = userEvent.setup()
    const store = renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /Do nothing/ }))
    const conditionsHeading = screen.getByText('Conditions', { selector: 'strong' })
    await user.click(conditionsHeading)
    const conditions = conditionsHeading.closest('details') as HTMLDetailsElement

    expect(within(conditions).getByText('Managed by Do nothing')).toBeInTheDocument()
    expect(within(conditions).getByText('Your Custom text conditions are retained and return when you switch modes.')).toBeInTheDocument()
    expect(within(conditions).queryByRole('combobox', { name: 'Add condition' })).not.toBeInTheDocument()
    expect(within(conditions).queryByRole('combobox', { name: 'Condition for simReturn' })).not.toBeInTheDocument()
    expect(store.getSnapshot().inserts.skipOutside.inputCondition).toBe('simReturn')
  })

  it('protects the .autoPaste built-in and keeps Do nothing explicit', async () => {
    const user = userEvent.setup()
    renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /autoPaste/ }))

    const deleteButton = screen.getByRole('button', { name: /Delete unavailable/ })
    expect(deleteButton).toBeDisabled()
    expect(within(screen.getByRole('combobox', { name: 'Payload mode' })).getByRole('option', { name: 'Do nothing' })).toBeInTheDocument()
    expect(screen.queryByText('Prototype mode')).not.toBeInTheDocument()
  })

  it('presents .none actions as Do nothing while retaining their stored name and value', async () => {
    const user = userEvent.setup()
    const store = renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))

    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    const skipOutside = within(actionList).getByRole('option', { name: /Do nothing/ })
    expect(skipOutside).toHaveTextContent('Do nothing')
    expect(skipOutside).toHaveTextContent('skipOutside')
    await user.click(skipOutside)

    expect(screen.getByRole('heading', { name: 'skipOutside', level: 1 })).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Rename' }))
    expect(screen.getByRole('textbox', { name: 'Action name' })).toHaveValue('skipOutside')
    expect(store.getSnapshot().inserts.skipOutside.action).toBe('.none')
    expect(screen.queryByText('.none')).not.toBeInTheDocument()
  })

  it('renames an Insert inline and keeps the canonical action identity in sync', async () => {
    const user = userEvent.setup()
    const store = renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /quickReply/ }))

    await user.click(screen.getByRole('button', { name: 'Rename' }))
    const name = screen.getByRole('textbox', { name: 'Action name' })
    await user.clear(name)
    await user.type(name, 'conciseReply')
    await user.click(screen.getByRole('button', { name: 'Save name' }))

    await waitFor(() => expect(screen.getByRole('heading', { name: 'conciseReply', level: 1 })).toBeInTheDocument())
    expect(store.getSnapshot().inserts.conciseReply).toBeDefined()
    expect(store.getSnapshot().inserts.quickReply).toBeUndefined()
    expect(within(actionList).getByRole('option', { name: /conciseReply/ })).toHaveAttribute('aria-selected', 'true')
  })

  it('keeps appearance choices keyboard-operable and presents one payload mode control', async () => {
    const user = userEvent.setup()
    renderWithStore()

    await user.click(screen.getByRole('button', { name: 'Preview mode' }))
    const appearance = screen.getByRole('radiogroup', { name: 'Appearance' })
    const light = within(appearance).getByRole('radio', { name: 'Light' })
    const dark = within(appearance).getByRole('radio', { name: 'Dark' })
    expect(light).toHaveAttribute('aria-checked', 'false')
    await user.click(light)
    expect(light).toHaveAttribute('aria-checked', 'true')
    light.focus()
    await user.keyboard('{ArrowRight}')
    expect(dark).toHaveAttribute('aria-checked', 'true')

    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /autoPaste/ }))
    const payloadMode = screen.getByRole('combobox', { name: 'Payload mode' })
    expect(payloadMode).toHaveValue('autoPaste')
    await user.selectOptions(payloadMode, 'text')
    await waitFor(() => expect(payloadMode).toHaveValue('text'))
    expect(screen.getByRole('textbox', { name: 'Insert payload' })).toHaveValue('')
    await user.selectOptions(payloadMode, 'none')
    await waitFor(() => expect(payloadMode).toHaveValue('none'))
  })

  it('retains and restores exact custom text when a built-in payload mode replaces it', async () => {
    const user = userEvent.setup()
    const store = renderWithStore('populated', 35)
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /quickReply/ }))

    const exactText = 'First line\n\n{{swResult::ensureSentence}}'
    const payload = screen.getByRole('textbox', { name: 'Insert payload' })
    fireEvent.change(payload, { target: { value: exactText, selectionStart: exactText.length } })
    await user.selectOptions(screen.getByRole('combobox', { name: 'Payload mode' }), 'none')
    await waitFor(() => expect(store.getSnapshot().inserts.quickReply.action).toBe('.none'))
    expect(screen.getByText('Custom text retained')).toBeInTheDocument()

    await user.click(within(actionList).getByRole('option', { name: /dailyNotes/ }))
    await user.click(within(actionList).getByRole('option', { name: /quickReply/ }))
    await user.click(screen.getByRole('button', { name: 'Restore custom text' }))
    await waitFor(() => expect(store.getSnapshot().inserts.quickReply.action).toBe('First line\\n\\n{{swResult::ensureSentence}}'))
    expect(screen.getByRole('textbox', { name: 'Insert payload' })).toHaveValue(exactText)
  })

  it('retains whitespace-only custom text exactly when changing payload modes', async () => {
    const user = userEvent.setup()
    const store = renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /quickReply/ }))

    const whitespace = ' \n  '
    fireEvent.change(screen.getByRole('textbox', { name: 'Insert payload' }), { target: { value: whitespace, selectionStart: whitespace.length } })
    await user.selectOptions(screen.getByRole('combobox', { name: 'Payload mode' }), 'autoPaste')
    await waitFor(() => expect(store.getSnapshot().inserts.quickReply.action).toBe('.autoPaste'))
    await user.click(screen.getByRole('button', { name: 'Restore custom text' }))
    await waitFor(() => expect(store.getSnapshot().inserts.quickReply.action).toBe(' \\n  '))
    expect(screen.getByRole('textbox', { name: 'Insert payload' })).toHaveValue(whitespace)
  })

  it('summarizes triggers, payload, conditions, insertion, and chaining without simulation', async () => {
    const user = userEvent.setup()
    renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /quickReply/ }))

    const summary = screen.getByLabelText('Effective behavior')
    expect(summary).toHaveTextContent('Triggered by 2 voice phrases, 3 front apps and 1 browser URL (all types must match)')
    expect(summary).toHaveTextContent('Inserts custom text')
    expect(summary).toHaveTextContent('2 conditions')
    expect(summary).toHaveTextContent('Stops after this action')

    await user.click(within(actionList).getByRole('option', { name: /Do nothing/ }))
    const builtInSummary = screen.getByLabelText('Effective behavior')
    expect(builtInSummary).toHaveTextContent('Triggered by 2 voice phrases')
    expect(builtInSummary).toHaveTextContent('Performs no payload')
    expect(builtInSummary).toHaveTextContent('Uses built-in input behavior')
  })

  it('keeps placeholder insertion organized and opens customization deliberately', async () => {
    const user = userEvent.setup()
    renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /quickReply/ }))

    await user.click(screen.getByRole('button', { name: /Insert placeholder/ }))
    const menu = screen.getByRole('menu', { name: 'Insert placeholder' })
    expect(menu).toHaveTextContent('Choose a value to insert.')
    expect(within(menu).getByRole('menuitem', { name: /Raw dictation/ })).toBeInTheDocument()
    expect(within(menu).getByRole('menuitem', { name: /^Language-model result/ })).toBeInTheDocument()
    expect(within(menu).getByRole('menuitem', { name: /Front app URL/ })).toBeInTheDocument()
    expect(within(menu).getByRole('menuitem', { name: /Recording folder path/ })).toBeInTheDocument()
    expect(within(menu).getByRole('menuitem', { name: /Action result/ })).toBeInTheDocument()
    expect(within(menu).queryByRole('menuitem', { name: /Uppercase/ })).not.toBeInTheDocument()
    expect(within(menu).queryByRole('menuitem', { name: /regex replacement/i })).not.toBeInTheDocument()
    expect(within(menu).getByRole('menuitem', { name: 'Result' })).toHaveAccessibleDescription('Language-model result when available, otherwise raw dictation.')
    expect(within(menu).getByRole('menuitem', { name: /Short date/ })).toBeInTheDocument()
    expect(within(menu).getByRole('menuitem', { name: /Long date/ })).toBeInTheDocument()
    expect(within(menu).getByRole('menuitem', { name: /ISO date/ })).toBeInTheDocument()
    expect(within(menu).getByRole('menuitem', { name: /Date and time/ })).toBeInTheDocument()
    expect(menu).not.toHaveTextContent('{{')
    expect(within(menu).queryByRole('combobox')).not.toBeInTheDocument()
    await user.keyboard('{Escape}')

    const payload = screen.getByRole('textbox', { name: 'Insert payload' }) as HTMLTextAreaElement
    const placeholderStart = payload.value.indexOf('{{swResult}}')
    payload.focus()
    payload.setSelectionRange(placeholderStart + 2, placeholderStart + 2)
    fireEvent.select(payload)
    expect(screen.queryByRole('region', { name: 'Edit placeholder' })).not.toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: /1 placeholder found/ }))
    const occurrence = within(screen.getByRole('listbox', { name: 'Placeholder occurrences' })).getByRole('option', { name: /Result/i })
    await user.click(occurrence)
    expect(screen.getByRole('region', { name: 'Edit placeholder' })).toBeInTheDocument()
    const source = screen.getByRole('combobox', { name: 'Placeholder source' })
    expect(within(source).getAllByRole('option')).toHaveLength(16)
    for (const label of ['Result', 'Raw dictation', 'Language-model result', 'Selected text', 'Clipboard context', 'Front app', 'Front app URL', 'App context', 'App vocabulary', 'Action result', 'Recording folder name', 'Recording folder path', 'Short date', 'Long date', 'ISO date', 'Date and time']) {
      expect(within(source).getByRole('option', { name: label })).toBeInTheDocument()
    }
    expect(screen.getByRole('combobox', { name: 'Placeholder transform' })).toBeInTheDocument()
    expect(screen.getByRole('option', { name: 'Title case · French' })).toBeInTheDocument()
    expect(screen.queryByText('Raw syntax', { selector: 'summary' })).not.toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Placeholder syntax reference' })).toBeInTheDocument()
    await user.click(occurrence)
    expect(screen.queryByRole('region', { name: 'Edit placeholder' })).not.toBeInTheDocument()
    expect(screen.getByRole('listbox', { name: 'Placeholder occurrences' })).toBeInTheDocument()
    expect(occurrence).toHaveAttribute('aria-selected', 'false')
  })

  it('uses the direct Insert menu date choices in the occurrence source selector', async () => {
    const user = userEvent.setup()
    renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /quickReply/ }))

    const payload = screen.getByRole('textbox', { name: 'Insert payload' }) as HTMLTextAreaElement
    await user.click(screen.getByRole('button', { name: /1 placeholder found/ }))
    await user.click(within(screen.getByRole('listbox', { name: 'Placeholder occurrences' })).getByRole('option', { name: /Result/i }))

    await user.selectOptions(screen.getByRole('combobox', { name: 'Placeholder source' }), 'date:yyyy-MM-dd')
    expect(payload.value).toContain('{{date:yyyy-MM-dd}}')
    expect(screen.getByRole('combobox', { name: 'Placeholder source' })).toHaveValue('date:yyyy-MM-dd')
    expect(screen.queryByRole('combobox', { name: 'Placeholder date format' })).not.toBeInTheDocument()

    await user.selectOptions(screen.getByRole('combobox', { name: 'Placeholder source' }), 'frontApp')
    expect(payload.value).toContain('{{frontApp}}')
    expect(payload.value).not.toContain('yyyy-MM-dd')
  })

  it('keeps placeholder review and Insert settings to one open panel', async () => {
    const user = userEvent.setup()
    renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /quickReply/ }))

    const review = screen.getByRole('button', { name: /1 placeholder found/ })
    const detailsFor = (label: string) => screen.getByText(label, { selector: 'strong' }).closest('details') as HTMLDetailsElement

    await user.click(review)
    expect(review).toHaveAttribute('aria-expanded', 'true')

    for (const label of ['Action overrides', 'Conditions', 'Triggers', 'Chaining']) {
      await user.click(screen.getByText(label, { selector: 'strong' }))
      expect(detailsFor(label)).toHaveAttribute('open')
      expect(review).toHaveAttribute('aria-expanded', 'false')
      for (const other of ['Action overrides', 'Conditions', 'Triggers', 'Chaining'].filter((item) => item !== label)) {
        expect(detailsFor(other)).not.toHaveAttribute('open')
      }
    }

    await user.click(review)
    expect(review).toHaveAttribute('aria-expanded', 'true')
    expect(detailsFor('Chaining')).not.toHaveAttribute('open')
    await user.click(review)
    expect(review).toHaveAttribute('aria-expanded', 'false')
  })

  it('supports keyboard-only placeholder discovery and insertion', async () => {
    const user = userEvent.setup()
    renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /quickReply/ }))

    const payload = screen.getByRole('textbox', { name: 'Insert payload' })
    const insertPlaceholder = screen.getByRole('button', { name: /Insert placeholder/ })
    insertPlaceholder.focus()
    await user.keyboard('{Enter}')
    const menu = screen.getByRole('menu', { name: 'Insert placeholder' })
    const result = within(menu).getByRole('menuitem', { name: 'Result' })
    const raw = within(menu).getByRole('menuitem', { name: 'Raw dictation' })
    const items = within(menu).getAllByRole('menuitem')

    expect(menu).toHaveFocus()
    expect(result).not.toHaveClass('is-keyboard-active')
    expect(result).toHaveAttribute('tabindex', '-1')
    expect(raw).toHaveAttribute('tabindex', '-1')
    expect(items.filter((item) => item.tabIndex === 0)).toHaveLength(0)
    expect(items.filter((item) => item.classList.contains('is-keyboard-active'))).toHaveLength(0)
    expect(result).toHaveAccessibleDescription('Language-model result when available, otherwise raw dictation.')
    await user.keyboard('{ArrowDown}')
    expect(result).toHaveFocus()
    expect(result).toHaveClass('is-keyboard-active')
    expect(result).toHaveAttribute('tabindex', '0')
    expect(items.filter((item) => item.tabIndex === 0)).toEqual([result])
    expect(items.filter((item) => item.classList.contains('is-keyboard-active'))).toEqual([result])
    await user.keyboard('{ArrowDown}')
    expect(raw).toHaveFocus()
    expect(raw).toHaveClass('is-keyboard-active')
    expect(raw).toHaveAttribute('tabindex', '0')
    expect(result).not.toHaveClass('is-keyboard-active')
    expect(result).toHaveAttribute('tabindex', '-1')
    expect(items.filter((item) => item.tabIndex === 0)).toEqual([raw])
    expect(items.filter((item) => item.classList.contains('is-keyboard-active'))).toEqual([raw])
    expect(raw).toHaveAccessibleDescription('The unprocessed Superwhisper result.')
    await user.keyboard('{Enter}')

    expect((payload as HTMLTextAreaElement).value).toContain('{{result}}')
    expect(payload).toHaveFocus()
    expect(screen.queryByRole('menu', { name: 'Insert placeholder' })).not.toBeInTheDocument()
  })

  it('keeps pointer hover independent from intentional keyboard selection', async () => {
    const user = userEvent.setup()
    renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /quickReply/ }))

    await user.click(screen.getByRole('button', { name: /Insert placeholder/ }))
    const menu = screen.getByRole('menu', { name: 'Insert placeholder' })
    const result = within(menu).getByRole('menuitem', { name: 'Result' })
    const raw = within(menu).getByRole('menuitem', { name: 'Raw dictation' })
    const languageModel = within(menu).getByRole('menuitem', { name: 'Language-model result' })
    const activeItems = () => within(menu).getAllByRole('menuitem').filter((item) => item.classList.contains('is-keyboard-active'))

    expect(menu).toHaveFocus()
    expect(menu).not.toHaveClass('is-keyboard-navigating')
    expect(activeItems()).toHaveLength(0)
    fireEvent.pointerMove(raw, { pointerType: 'mouse' })
    expect(raw).not.toHaveFocus()
    expect(menu).not.toHaveClass('is-keyboard-navigating')
    expect(activeItems()).toHaveLength(0)
    fireEvent.pointerMove(languageModel, { pointerType: 'mouse' })
    expect(languageModel).not.toHaveFocus()
    expect(activeItems()).toHaveLength(0)
    expect(result).toHaveAttribute('tabindex', '-1')

    await user.keyboard('{ArrowUp}')
    const lastItem = within(menu).getAllByRole('menuitem').at(-1) as HTMLButtonElement
    expect(lastItem).toHaveFocus()
    expect(menu).toHaveClass('is-keyboard-navigating')
    expect(activeItems()).toEqual([lastItem])

    fireEvent.pointerMove(raw, { pointerType: 'mouse' })
    expect(menu).not.toHaveClass('is-keyboard-navigating')
    expect(activeItems()).toHaveLength(0)
    expect(raw).not.toHaveFocus()
  })

  it('collapses placeholder review after inserting from the palette', async () => {
    const user = userEvent.setup()
    renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /quickReply/ }))

    const review = screen.getByRole('button', { name: /1 placeholder found/ })
    await user.click(review)
    expect(review).toHaveAttribute('aria-expanded', 'true')

    await user.click(screen.getByRole('button', { name: /Insert placeholder/ }))
    await user.click(within(screen.getByRole('menu', { name: 'Insert placeholder' })).getByRole('menuitem', { name: 'Result' }))

    expect(screen.getByRole('button', { name: /2 placeholders found/ })).toHaveAttribute('aria-expanded', 'false')
    expect(screen.queryByRole('listbox', { name: 'Placeholder occurrences' })).not.toBeInTheDocument()
  })

  it('encodes literal double pipes in regex replacement stages for parser round-trips', async () => {
    const user = userEvent.setup()
    renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /quickReply/ }))

    const payload = screen.getByRole('textbox', { name: 'Insert payload' }) as HTMLTextAreaElement
    await user.click(screen.getByRole('button', { name: /1 placeholder found/ }))
    await user.click(within(screen.getByRole('listbox', { name: 'Placeholder occurrences' })).getByRole('option', { name: /Result/i }))
    await user.click(screen.getByRole('button', { name: /Add replacement/ }))
    await user.type(screen.getByRole('textbox', { name: 'Find pattern 1' }), '||')
    await user.type(screen.getByRole('textbox', { name: 'Replacement text 1' }), '||')

    const expression = '{{swResult||\\|\\|||\\|\\|}}'
    expect(payload.value).toContain(expression)
  })

  it('serializes actual Returns in regex replacement helpers as Macrowhisper newline tokens', async () => {
    const user = userEvent.setup()
    renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /quickReply/ }))

    const payload = screen.getByRole('textbox', { name: 'Insert payload' }) as HTMLTextAreaElement
    await user.click(screen.getByRole('button', { name: /1 placeholder found/ }))
    await user.click(within(screen.getByRole('listbox', { name: 'Placeholder occurrences' })).getByRole('option', { name: /Result/i }))
    await user.click(screen.getByRole('button', { name: /Add replacement/ }))
    fireEvent.change(screen.getByRole('textbox', { name: 'Find pattern 1' }), { target: { value: 'middle' } })
    fireEvent.change(screen.getByRole('textbox', { name: 'Replacement text 1' }), { target: { value: 'line 1\nline 2' } })

    expect(screen.getByText(/Use.*for a capture group/)).toHaveTextContent('Use ${1} for a capture group, or ${1::titleCase} to transform it.')
    expect(screen.queryByText(/Press Return for a new line/)).not.toBeInTheDocument()
    const expression = '{{swResult||middle||line 1\\nline 2}}'
    expect(payload.value).toContain(expression)
  })

  it('shows canonical newline tokens as Returns and preserves literal backslash+n spellings', async () => {
    const user = userEvent.setup()
    renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /quickReply/ }))

    const payload = screen.getByRole('textbox', { name: 'Insert payload' }) as HTMLTextAreaElement
    const legacySingleSlash = '{{swResult||middle||\\n}}'
    fireEvent.change(payload, { target: { value: legacySingleSlash } })
    await user.click(screen.getByRole('button', { name: /1 placeholder found/ }))
    await user.click(within(screen.getByRole('listbox', { name: 'Placeholder occurrences' })).getByRole('option', { name: /Result/i }))

    const replacement = screen.getByRole('textbox', { name: 'Replacement text 1' })
    expect(replacement).toHaveValue('\n')
    fireEvent.change(screen.getByRole('textbox', { name: 'Find pattern 1' }), { target: { value: 'center' } })
    expect(payload).toHaveValue('{{swResult||center||\\n}}')

    await user.clear(replacement)
    await user.type(replacement, 'before\\nafter')
    expect(replacement).toHaveValue('before\nafter')
    expect(payload).toHaveValue('{{swResult||center||before\\nafter}}')

    const legacyDoubleSlash = '{{swResult||middle||\\\\n}}'
    fireEvent.change(payload, { target: { value: legacyDoubleSlash } })
    await user.click(within(screen.getByRole('listbox', { name: 'Placeholder occurrences' })).getByRole('option', { name: /Result/i }))
    const doubleSlashReplacement = screen.getByRole('textbox', { name: 'Replacement text 1' })
    expect(doubleSlashReplacement).toHaveValue('\\\\n')
    expect(payload).toHaveValue(legacyDoubleSlash)

    fireEvent.change(doubleSlashReplacement, { target: { value: 'before\\\\nafter' } })
    expect(doubleSlashReplacement).toHaveValue('before\\\\nafter')
    expect(payload).toHaveValue('{{swResult||middle||before\\\\nafter}}')

    // An unrelated edit must not reinterpret the visible escaped literal.
    await user.type(doubleSlashReplacement, ' tail')
    expect(doubleSlashReplacement).toHaveValue('before\\\\nafter tail')
    expect(payload).toHaveValue('{{swResult||middle||before\\\\nafter tail}}')

    // A literal slash immediately before a Return is displayed as a doubled
    // slash and needs the odd v3 run (`\\\\\\n`) on the wire.
    const slashAndReturn = 'before' + '\\\\' + '\n' + 'after'
    fireEvent.change(doubleSlashReplacement, { target: { value: slashAndReturn } })
    expect(doubleSlashReplacement).toHaveValue(slashAndReturn)
    expect(payload).toHaveValue('{{swResult||middle||before\\\\\\n' + 'after}}')
  })

  it('renders ordinary Insert text as multiline while keeping complete placeholders inline', async () => {
    const user = userEvent.setup()
    const store = renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /quickReply/ }))

    const payload = screen.getByRole('textbox', { name: 'Insert payload' }) as HTMLTextAreaElement
    const canonical = 'Capture this:\\n\\n{{swResult||middle||New\\nLine}}\\nLiteral \\\\n'
    act(() => {
      store.simulateExternalChange({ path: ['inserts', 'quickReply', 'action'], operation: 'set', value: canonical })
    })

    await waitFor(() => expect(payload).toHaveValue('Capture this:\n\n{{swResult||middle||New\\nLine}}\nLiteral \\\\n'))
    expect(screen.getByRole('button', { name: /1 placeholder found/ })).toBeInTheDocument()
  })

  it('normalizes a Return inside a complete placeholder only when the payload commits', async () => {
    const user = userEvent.setup()
    const store = renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /quickReply/ }))

    const payload = screen.getByRole('textbox', { name: 'Insert payload' }) as HTMLTextAreaElement
    const editingValue = 'Before\n{{swResult||middle||New\nLine}}\nAfter'
    fireEvent.change(payload, { target: { value: editingValue } })

    // Do not replace text under the caret while the user is still composing.
    expect(payload).toHaveValue(editingValue)
    fireEvent.blur(payload)

    await waitFor(() => expect(store.getSnapshot().inserts.quickReply.action).toBe('Before\\n{{swResult||middle||New\\nLine}}\\nAfter'))
    expect(payload).toHaveValue('Before\n{{swResult||middle||New\\nLine}}\nAfter')
  })

  it('keeps an incomplete hand-written placeholder visually multiline after save', async () => {
    const user = userEvent.setup()
    const store = renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /quickReply/ }))

    const payload = screen.getByRole('textbox', { name: 'Insert payload' }) as HTMLTextAreaElement
    const incomplete = 'Before\n{{swResult||middle||New\nLine'
    fireEvent.change(payload, { target: { value: incomplete } })
    fireEvent.blur(payload)

    await waitFor(() => expect(store.getSnapshot().inserts.quickReply.action).toBe('Before\\n{{swResult||middle||New\\nLine'))
    expect(payload).toHaveValue(incomplete)
  })

  it('edits XML placeholders while preserving prefixes, repeated occurrences, and malformed syntax', async () => {
    const user = userEvent.setup()
    renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /quickReply/ }))

    const payload = screen.getByRole('textbox', { name: 'Insert payload' }) as HTMLTextAreaElement
    const malformedTag = '{{xml:bad-tag::uppercase}}'
    const malformedReplacement = '{{xml:answer||odd}}'
    const malformedPrefix = '{{json:raw:xml:answer}}'
    fireEvent.change(payload, { target: { value: `A {{swResult}} B {{json:swResult}} C {{raw:custom.path::titleCase}} D {{xml:answer}} E {{json:xml:answer}} F {{raw:xml:OtherTag||A||B||B||C}} G {{xml:answer}} H ${malformedTag} I ${malformedReplacement} J ${malformedPrefix}` } })
    expect(screen.queryByRole('region', { name: 'Edit placeholder' })).not.toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: /10 placeholders found/ }))
    const list = screen.getByRole('listbox', { name: 'Placeholder occurrences' })
    const resultOccurrences = within(list).getAllByRole('option', { name: /Result/i })
    expect(resultOccurrences).toHaveLength(2)
    await user.click(resultOccurrences[1])
    await user.selectOptions(screen.getByRole('combobox', { name: 'Placeholder transform' }), 'uppercase')
    expect(payload.value).toContain('A {{swResult}} B {{json:swResult::uppercase}} C {{raw:custom.path::titleCase}} D {{xml:answer}}')

    await user.click(within(list).getByRole('option', { name: /custom\.path/ }))
    expect(screen.queryByText('Metadata key or path preserved exactly.')).not.toBeInTheDocument()
    expect(screen.queryByRole('combobox', { name: 'Placeholder source' })).not.toBeInTheDocument()
    expect(screen.getByText('custom.path', { selector: '.placeholder-fixed-source code' })).toBeInTheDocument()
    await user.selectOptions(screen.getByRole('combobox', { name: 'Placeholder transform' }), 'lowercase')
    expect(payload.value).toContain('{{raw:custom.path::lowercase}}')
    expect(payload.value).toContain('{{xml:answer}}')

    await user.click(screen.getByRole('button', { name: 'Add replacement' }))
    fireEvent.change(screen.getByRole('textbox', { name: 'Find pattern 1' }), { target: { value: 'path' } })
    fireEvent.change(screen.getByRole('textbox', { name: 'Replacement text 1' }), { target: { value: 'value' } })
    expect(payload.value).toContain('{{raw:custom.path::lowercase||path||value}}')

    let xmlOccurrences = within(list).getAllByRole('option', { name: /XML placeholder/ })
    expect(xmlOccurrences).toHaveLength(4)

    // A plain XML tag is a fixed source, but uses the same transform editor.
    await user.click(xmlOccurrences[0])
    expect(screen.queryByRole('combobox', { name: 'Placeholder source' })).not.toBeInTheDocument()
    expect(screen.getByText('answer', { selector: '.placeholder-fixed-source code' })).toBeInTheDocument()
    await user.selectOptions(screen.getByRole('combobox', { name: 'Placeholder transform' }), 'uppercase')
    expect(payload.value).toContain('{{xml:answer::uppercase}}')

    // Prefixes and tag names survive structured edits.
    await user.click(within(list).getByRole('option', { name: /json:xml:answer/ }))
    expect(screen.queryByRole('combobox', { name: 'Placeholder source' })).not.toBeInTheDocument()
    expect(screen.getByText('answer', { selector: '.placeholder-fixed-source code' })).toBeInTheDocument()
    await user.selectOptions(screen.getByRole('combobox', { name: 'Placeholder transform' }), 'lowercase')
    await user.click(screen.getByRole('button', { name: 'Add replacement' }))
    fireEvent.change(screen.getByRole('textbox', { name: 'Find pattern 1' }), { target: { value: 'A' } })
    fireEvent.change(screen.getByRole('textbox', { name: 'Replacement text 1' }), { target: { value: 'B' } })
    expect(payload.value).toContain('{{json:xml:answer::lowercase||A||B}}')

    // A raw-prefixed XML tag is editable with the same fixed-source controls.
    await user.click(within(list).getByRole('option', { name: /raw:xml:OtherTag/ }))
    expect(screen.queryByRole('combobox', { name: 'Placeholder source' })).not.toBeInTheDocument()
    expect(screen.getByText('OtherTag', { selector: '.placeholder-fixed-source code' })).toBeInTheDocument()
    expect(screen.getByRole('textbox', { name: 'Find pattern 1' })).toHaveValue('A')
    expect(screen.getByRole('textbox', { name: 'Find pattern 2' })).toHaveValue('B')
    await user.selectOptions(screen.getByRole('combobox', { name: 'Placeholder transform' }), 'trim')
    expect(payload.value).toContain('{{raw:xml:OtherTag::trim||A||B||B||C}}')

    // Repeated XML occurrences are independent entries.
    xmlOccurrences = within(list).getAllByRole('option', { name: /XML placeholder/ })
    await user.click(xmlOccurrences[3])
    await user.selectOptions(screen.getByRole('combobox', { name: 'Placeholder transform' }), 'lowercase')
    expect(payload.value).toContain('G {{xml:answer::lowercase}}')

    // Unsupported XML syntax stays raw and is never normalized by another edit.
    const rawOccurrences = within(list).getAllByRole('option', { name: /Raw placeholder/ })
    expect(rawOccurrences).toHaveLength(3)
    await user.click(rawOccurrences[0])
    const rawInspector = screen.getByRole('region', { name: 'Edit placeholder' })
    expect(within(rawInspector).getByText('Raw placeholder')).toBeInTheDocument()
    expect(within(rawInspector).getByText(malformedTag)).toBeInTheDocument()
    expect(screen.queryByRole('combobox', { name: 'Placeholder transform' })).not.toBeInTheDocument()
    expect(payload.value).toContain(malformedTag)
    expect(payload.value).toContain(malformedReplacement)
    expect(payload.value).toContain(malformedPrefix)
  })

  it('preserves indexed action results while editing transforms', async () => {
    const user = userEvent.setup()
    renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /quickReply/ }))

    const payload = screen.getByRole('textbox', { name: 'Insert payload' }) as HTMLTextAreaElement
    fireEvent.change(payload, { target: { value: '{{actionResult:1}}' } })
    await user.click(screen.getByRole('button', { name: /1 placeholder found/ }))
    await user.click(within(screen.getByRole('listbox', { name: 'Placeholder occurrences' })).getByRole('option', { name: /Action result/ }))
    expect(screen.getByRole('textbox', { name: 'Placeholder index' })).toHaveValue('1')
    await user.selectOptions(screen.getByRole('combobox', { name: 'Placeholder transform' }), 'titleCase:fr')
    expect(payload).toHaveValue('{{actionResult:1::titleCase:fr}}')
  })

  it('validates indexed sources without rewriting invalid drafts or direct configuration', async () => {
    const user = userEvent.setup()
    renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /quickReply/ }))

    const payload = screen.getByRole('textbox', { name: 'Insert payload' }) as HTMLTextAreaElement
    fireEvent.change(payload, { target: { value: '{{folderPath:2::lowercase||/Users||~}}' } })
    await user.click(screen.getByRole('button', { name: /1 placeholder found/ }))
    await user.click(within(screen.getByRole('listbox', { name: 'Placeholder occurrences' })).getByRole('option', { name: /Recording folder path/ }))

    const index = screen.getByRole('textbox', { name: 'Placeholder index' })
    expect(index).toHaveValue('2')
    expect(screen.getByRole('combobox', { name: 'Placeholder transform' })).toHaveValue('lowercase')
    expect(screen.getByRole('textbox', { name: 'Find pattern 1' })).toHaveValue('/Users')

    fireEvent.change(index, { target: { value: 'two' } })
    expect(index).toHaveValue('two')
    expect(index).toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByText(/Use digits only/)).toBeInTheDocument()
    expect(payload).toHaveValue('{{folderPath:2::lowercase||/Users||~}}')

    fireEvent.change(index, { target: { value: '3' } })
    expect(index).toHaveValue('3')
    expect(index).not.toHaveAttribute('aria-invalid')
    expect(payload).toHaveValue('{{folderPath:3::lowercase||/Users||~}}')

    fireEvent.change(index, { target: { value: '' } })
    expect(payload).toHaveValue('{{folderPath::lowercase||/Users||~}}')

    fireEvent.change(payload, { target: { value: '{{folderName:invalid}}' } })
    await user.click(within(screen.getByRole('listbox', { name: 'Placeholder occurrences' })).getByRole('option', { name: /Recording folder name/ }))
    const invalidSavedIndex = screen.getByRole('textbox', { name: 'Placeholder index' })
    expect(invalidSavedIndex).toHaveValue('invalid')
    expect(invalidSavedIndex).toHaveAttribute('aria-invalid', 'true')
    expect(payload).toHaveValue('{{folderName:invalid}}')

    fireEvent.change(invalidSavedIndex, { target: { value: '1' } })
    expect(payload).toHaveValue('{{folderName:1}}')
  })

  it('reorders multiline regex stages without separating patterns from replacements', async () => {
    const user = userEvent.setup()
    renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /quickReply/ }))

    const payload = screen.getByRole('textbox', { name: 'Insert payload' }) as HTMLTextAreaElement
    fireEvent.change(payload, { target: { value: '{{swResult||one||1||two||2}}' } })
    await user.click(screen.getByRole('button', { name: /1 placeholder found/ }))
    await user.click(within(screen.getByRole('listbox', { name: 'Placeholder occurrences' })).getByRole('option', { name: /Result/i }))
    expect(screen.getByRole('textbox', { name: 'Find pattern 1' }).tagName).toBe('TEXTAREA')
    await user.click(screen.getByRole('button', { name: 'Move replacement 2 up' }))
    expect(payload).toHaveValue('{{swResult||two||2||one||1}}')
  })

  it('does not flag recognized raw trigger modes, but requires opt-in for incompatible syntax', async () => {
    const user = userEvent.setup()
    const store = renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /quickReply/ }))

    act(() => {
      store.simulateExternalChange({ path: ['inserts', 'quickReply', 'triggerVoice'], operation: 'set', value: '==^(reply|respond)$==' })
    })
    await waitFor(() => expect(screen.getByRole('combobox', { name: 'Voice trigger mode' })).toHaveValue('regex'))
    expect(screen.queryByText(/saved trigger expression needs Advanced raw mode/)).not.toBeInTheDocument()

    act(() => {
      store.simulateExternalChange({ path: ['inserts', 'quickReply', 'triggerApps'], operation: 'set', value: 'Mail||Messages' })
    })
    await waitFor(() => expect(screen.getByText(/saved trigger expression needs Advanced raw mode/)).toBeInTheDocument())
    const frontApps = screen.getByLabelText('Advanced Front apps')
    await user.click(within(frontApps.closest('.trigger-field') as HTMLElement).getByRole('checkbox', { name: 'Advanced raw mode' }))
    expect(screen.queryByText(/saved trigger expression needs Advanced raw mode/)).not.toBeInTheDocument()

    act(() => {
      store.simulateExternalChange({ path: ['inserts', 'quickReply', 'triggerVoice'], operation: 'set', value: 'foo||bar' })
    })
    await waitFor(() => expect(screen.getByText(/saved trigger expression needs Advanced raw mode/)).toBeInTheDocument())
    await user.selectOptions(screen.getByRole('combobox', { name: 'Voice trigger mode' }), 'advanced')
    expect(screen.queryByText(/saved trigger expression needs Advanced raw mode/)).not.toBeInTheDocument()
  })

  it('inserts a placeholder at the saved caret while keeping the payload toolbar composite', async () => {
    const user = userEvent.setup()
    renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /quickReply/ }))

    const payload = screen.getByRole('textbox', { name: 'Insert payload' }) as HTMLTextAreaElement
    const original = payload.value
    payload.focus()
    payload.setSelectionRange(0, 0)
    await user.click(screen.getByRole('button', { name: /Insert placeholder/ }))
    const placeholderMenu = screen.getByRole('menu', { name: 'Insert placeholder' })
    await user.click(within(placeholderMenu).getByRole('menuitem', { name: 'Result' }))

    expect(payload).toHaveValue('{{swResult}}' + original)
    expect(payload).toHaveFocus()
    expect(screen.getByRole('button', { name: /2 placeholders found/ })).toHaveAttribute('aria-expanded', 'false')
    expect(screen.queryByRole('listbox', { name: 'Placeholder occurrences' })).not.toBeInTheDocument()
    expect(screen.queryByRole('region', { name: 'Edit placeholder' })).not.toBeInTheDocument()
    // Moving to another editor section commits once, after the toolbar menu
    // has finished, instead of saving the pre-insertion value on blur.
    await user.click(screen.getByRole('heading', { name: 'Payload' }))
    await screen.findByText('Updated in preview', {}, { timeout: 1500 })
    expect(payload).toHaveValue('{{swResult}}' + original)
  })

  it('uses a native modal dialog with focus restoration for deletion confirmation', async () => {
    const user = userEvent.setup()
    renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /quickReply/ }))
    await user.click(screen.getByRole('button', { name: 'Delete' }))

    const dialog = screen.getByRole('dialog', { name: /Delete/ })
    expect(dialog.tagName).toBe('DIALOG')
    const cancel = within(dialog).getByRole('button', { name: 'Cancel' })
    expect(cancel).toHaveFocus()
    await user.keyboard('{Escape}')
    expect(screen.queryByRole('dialog', { name: /Delete/ })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Delete' })).toHaveFocus()
  })

  it('uses the mobile navigation as a sequential action browser', async () => {
    installMediaQuery(true)
    const user = userEvent.setup()
    renderWithStore()
    const menu = screen.getByRole('button', { name: /Menu/ })
    await user.click(menu)

    const sidebar = screen.getByRole('dialog', { name: 'Configuration navigation' })
    expect(sidebar).toHaveAttribute('aria-modal', 'true')
    expect(sidebar).not.toHaveAttribute('aria-hidden', 'true')
    await user.click(within(sidebar).getByRole('button', { name: /^Inserts/ }))
    const actionList = within(sidebar).getByRole('navigation', { name: 'Insert actions' })
    expect(screen.getByRole('heading', { name: 'Defaults' })).toBeInTheDocument()
    await user.click(within(actionList).getByRole('option', { name: /dailyNotes/ }))
    expect(screen.queryByRole('dialog', { name: 'Configuration navigation' })).not.toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'dailyNotes' })).toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Inserts' }))
    expect(screen.getByRole('dialog', { name: 'Configuration navigation' })).toBeInTheDocument()
    await user.keyboard('{Escape}')
    expect(screen.queryByRole('dialog', { name: 'Configuration navigation' })).not.toBeInTheDocument()
    expect(menu).toHaveFocus()
  })

  it('acknowledges a choice immediately and persists the selected value', async () => {
    const user = userEvent.setup()
    const store = renderWithStore('populated', 35)
    const control = screen.getByRole('combobox', { name: 'Simulate Escape' })

    await user.selectOptions(control, 'off')

    await waitFor(() => expect(screen.getAllByText('Updating preview…').length).toBeGreaterThan(0))
    await waitFor(() => expect(store.getSnapshot().defaults.simEsc).toBe(false), { timeout: 1000 })
    await waitForSaved()
    expect(control).toHaveValue('off')
  })

  it('removes a preview acknowledgement after its transient window', async () => {
    const user = userEvent.setup()
    renderWithStore()
    await user.selectOptions(screen.getByRole('combobox', { name: 'Simulate Escape' }), 'off')
    await waitForSaved()
    await waitFor(() => expect(screen.queryByText('Updated in preview')).not.toBeInTheDocument(), { timeout: 2300 })
  })

  it('offers Use built-in in a stable utility area only while a root field differs from its shipped value', async () => {
    const user = userEvent.setup()
    const store = renderWithStore()
    const control = screen.getByRole('textbox', { name: 'Action delay' })
    const row = control.closest('.setting-row') as HTMLElement
    const utility = row.querySelector('.setting-utility') as HTMLElement

    expect(utility).toBeInTheDocument()
    expect(row.querySelector('.setting-copy')?.contains(utility)).toBe(false)
    expect(within(utility).queryByRole('button', { name: 'Use built-in' })).not.toBeInTheDocument()
    await user.clear(control)
    await user.type(control, '0.2')
    fireEvent.blur(control)

    await waitFor(() => expect(store.getSnapshot().defaults.actionDelay).toBe(0.2))
    const useBuiltIn = within(utility).getByRole('button', { name: 'Use built-in' })
    expect(within(row.querySelector('.setting-control') as HTMLElement).queryByRole('button', { name: 'Use built-in' })).not.toBeInTheDocument()
    await user.click(useBuiltIn)

    await waitFor(() => expect(store.getSnapshot().defaults.actionDelay).toBeNull())
    expect(within(utility).queryByRole('button', { name: 'Use built-in' })).not.toBeInTheDocument()
    expect(utility).toBeInTheDocument()
  })

  it('keeps the custom icon input mounted and identifiable when its draft is cleared', async () => {
    const user = userEvent.setup()
    renderWithStore()
    const iconMode = screen.getByRole('combobox', { name: 'Default icon mode' })
    const row = iconMode.closest('.setting-row') as HTMLElement

    await user.selectOptions(iconMode, 'custom')
    const customIcon = screen.getByRole('textbox', { name: 'Custom icon' })
    await user.type(customIcon, '4')
    await user.clear(customIcon)

    expect(customIcon).toBeInTheDocument()
    expect(customIcon).toHaveValue('')
    expect(row.querySelector('.nullable-control > input')).toBe(customIcon)
    expect(within(row).getByText('Unsaved')).toBeInTheDocument()
  })

  it('lets pointer and keyboard Revert discard a focused draft without saving it', async () => {
    const user = userEvent.setup()
    const store = renderWithStore()
    const mutate = vi.spyOn(store, 'mutate')
    const control = screen.getByRole('textbox', { name: 'Superwhisper folder' })
    const initial = store.getSnapshot().defaults.watch

    await user.clear(control)
    await user.type(control, '~/Documents/pointer-draft')
    await user.click(screen.getByRole('button', { name: 'Revert' }))
    expect(control).toHaveValue(initial)
    expect(mutate).not.toHaveBeenCalled()

    await user.clear(control)
    await user.type(control, '~/Documents/keyboard-draft')
    const revert = screen.getByRole('button', { name: 'Revert' })
    await user.tab({ shift: true })
    expect(revert).toHaveFocus()
    await user.keyboard('{Enter}')
    expect(control).toHaveValue(initial)
    expect(mutate).not.toHaveBeenCalled()
  })

  it('uses built-in numeric Defaults when an ordinary numeric field is left blank', async () => {
    const user = userEvent.setup()
    const store = renderWithStore()
    const actionDelay = screen.getByRole('textbox', { name: 'Action delay' })

    await user.clear(actionDelay)
    fireEvent.blur(actionDelay)
    await waitFor(() => expect(store.getSnapshot().defaults.actionDelay).toBeNull())
    expect(actionDelay).toHaveValue('')
    expect(screen.queryByText('Use a number for this field.')).not.toBeInTheDocument()

    await user.selectOptions(screen.getByRole('combobox', { name: 'Press Return after insert' }), 'on')
    const returnDelay = screen.getByRole('textbox', { name: 'Return delay' })
    await user.clear(returnDelay)
    await user.keyboard('{Enter}')
    await waitFor(() => expect(store.getSnapshot().defaults.returnDelay).toBeNull())
    expect(returnDelay).toHaveValue('')
  })

  it('keeps invalid numeric Defaults local and reports a concise field error', async () => {
    const user = userEvent.setup()
    const store = renderWithStore()
    const actionDelay = screen.getByRole('textbox', { name: 'Action delay' })

    await user.clear(actionDelay)
    await user.type(actionDelay, '2d')
    fireEvent.blur(actionDelay)

    const error = await screen.findByText('Enter a valid number.')
    expect(actionDelay).toHaveAttribute('aria-invalid', 'true')
    expect(error.closest('.setting-control')).not.toBeNull()
    expect(screen.queryByRole('button', { name: 'Retry' })).not.toBeInTheDocument()
    expect(store.getSnapshot().defaults.actionDelay).toBe(0)
  })

  it('keeps an explicit zero distinct from an unset numeric Default', async () => {
    const user = userEvent.setup()
    const store = renderWithStore()
    const timeout = screen.getByRole('textbox', { name: 'Scheduled action timeout' })

    await user.clear(timeout)
    await user.type(timeout, '0')
    fireEvent.blur(timeout)
    await waitFor(() => expect(store.getSnapshot().defaults.scheduledActionTimeout).toBe(0))
    expect(timeout).toHaveValue('0')
  })

  it('keeps text edits local until the control blurs', async () => {
    const user = userEvent.setup()
    const store = renderWithStore()
    const control = screen.getByRole('textbox', { name: 'Superwhisper folder' })
    const initial = store.getSnapshot().defaults.watch

    await user.clear(control)
    await user.type(control, '~/Documents/recordings')

    expect(store.getSnapshot().defaults.watch).toBe(initial)
    expect(screen.getByText('Unsaved')).toBeInTheDocument()

    fireEvent.blur(control)
    await waitFor(() => expect(store.getSnapshot().defaults.watch).toBe('~/Documents/recordings'))
    await waitForSaved()
  })

  it('updates a saved control when an external revision changes its value', async () => {
    const user = userEvent.setup()
    const store = renderWithStore()
    const control = screen.getByRole('combobox', { name: 'Simulate Escape' })

    await user.selectOptions(control, 'off')
    await waitFor(() => expect(store.getSnapshot().defaults.simEsc).toBe(false))
    await waitForSaved()

    act(() => {
      store.simulateExternalChange({ path: ['defaults', 'simEsc'], operation: 'set', value: true })
    })

    await waitFor(() => expect(control).toHaveValue('on'))
    expect(store.getSnapshot().defaults.simEsc).toBe(true)
  })

  it('serializes rapid changes to different controls against each revision', async () => {
    const user = userEvent.setup()
    const store = renderWithStore('populated', 25)
    const escape = screen.getByRole('combobox', { name: 'Simulate Escape' })
    const notifications = screen.getByRole('combobox', { name: 'System notifications' })

    await user.selectOptions(escape, 'off')
    await user.selectOptions(notifications, 'on')

    await waitFor(() => {
      expect(store.getSnapshot().defaults.simEsc).toBe(false)
      expect(store.getSnapshot().defaults.muteNotifications).toBe(true)
    }, { timeout: 1500 })
    expect(escape).toHaveValue('off')
    expect(notifications).toHaveValue('on')
    await waitForSaved()
  })

  it('keeps a dirty draft and its external baseline through an independent save', async () => {
    const user = userEvent.setup()
    const store = renderWithStore()
    const watch = screen.getByRole('textbox', { name: 'Superwhisper folder' })
    const escape = screen.getByRole('combobox', { name: 'Simulate Escape' })

    await user.clear(watch)
    await user.type(watch, '~/Documents/local-draft')
    expect(watch).toHaveValue('~/Documents/local-draft')
    expect(screen.getByText('Unsaved')).toBeInTheDocument()

    act(() => {
      store.simulateExternalChange({ path: ['defaults', 'watch'], operation: 'set', value: '~/Documents/remote-folder' })
    })
    expect(watch).toHaveValue('~/Documents/local-draft')
    expect(store.getSnapshot().defaults.watch).toBe('~/Documents/remote-folder')

    // Dispatch the independent choice without moving focus away from the
    // text control. A real pointer selection would blur the draft and
    // intentionally save it.
    fireEvent.change(escape, { target: { value: 'off' } })
    await waitFor(() => expect(store.getSnapshot().defaults.simEsc).toBe(false))
    expect(watch).toHaveValue('~/Documents/local-draft')
    expect(screen.getByText('Unsaved')).toBeInTheDocument()
    expect(store.getSnapshot().defaults.watch).toBe('~/Documents/remote-folder')
  })

  it('recovers a conflicted Insert after reviewing the remote value', async () => {
    const user = userEvent.setup()
    const store = renderWithStore('conflict')
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /quickReply/ }))

    const payload = screen.getByRole('textbox', { name: 'Insert payload' })
    const desired = 'A locally re-applied payload.'
    await user.clear(payload)
    await user.type(payload, desired)
    fireEvent.blur(payload)

    const review = await screen.findByRole('button', { name: /Review current value|Resync/ }, { timeout: 1500 })
    expect(store.getSnapshot().revision.version).toBeGreaterThan(7)
    expect(store.getSnapshot().inserts.quickReply.action).not.toBe(desired)

    await user.click(review)
    await user.click(screen.getByRole('button', { name: 'Reapply draft' }))

    await waitFor(() => expect(store.getSnapshot().inserts.quickReply.action).toBe(desired), { timeout: 1500 })
    await waitForSaved()
    expect(payload).toHaveValue(desired)
  })
})
