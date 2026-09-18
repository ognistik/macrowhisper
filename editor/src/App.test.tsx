import { act, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import App, { defaultFieldGroups, DEFAULTS_OPEN_SECTION_STORAGE_KEY, overrideFields } from './App'
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

  it('restores a persisted Defaults section and explicit all-collapsed state', async () => {
    const user = userEvent.setup()
    const storage = (window as Window & { localStorage?: Storage }).localStorage
    if (!storage) return
    const first = render(<App store={new FixtureStore('populated')} />)
    const insertionTitle = screen.getByText('Insertion', { selector: 'strong' })
    expect(defaultFieldGroups.every((section) => !screen.getByText(section.label, { selector: 'strong' }).closest('details')?.hasAttribute('open'))).toBe(true)
    await user.click(insertionTitle)
    expect(storage.getItem(DEFAULTS_OPEN_SECTION_STORAGE_KEY)).toBe('insertion')
    first.unmount()

    render(<App store={new FixtureStore('populated')} />)
    const restoredInsertion = screen.getByText('Insertion', { selector: 'strong' }).closest('details')
    expect(restoredInsertion).toHaveAttribute('open')
    await user.click(screen.getByText('Insertion', { selector: 'strong' }))
    expect(storage.getItem(DEFAULTS_OPEN_SECTION_STORAGE_KEY)).toBe('')
    screen.getByText('General behavior', { selector: 'strong' })
    expect(screen.getByText('General behavior', { selector: 'strong' }).closest('details')).not.toHaveAttribute('open')
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
    renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    expect(within(actionList).queryByRole('button', { name: 'Duplicate' })).not.toBeInTheDocument()
    await user.click(within(actionList).getByRole('option', { name: /dailyNotes/ }))

    await user.click(screen.getByText('Insertion behavior', { selector: 'strong' }))
    const insertion = screen.getByText('Insertion behavior', { selector: 'strong' }).closest('details')
    expect(insertion).not.toBeNull()
    expect(within(insertion!).getByText('Using Defaults')).toBeInTheDocument()
    expect(screen.queryByRole('combobox', { name: 'Simulate Escape' })).not.toBeInTheDocument()
    await user.selectOptions(screen.getByRole('combobox', { name: 'Add override' }), 'simEsc')
    expect(screen.getByRole('combobox', { name: 'Simulate Escape' })).toBeInTheDocument()
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
    await waitFor(() => expect(store.getSnapshot().inserts.quickReply.action).toBe(exactText))
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
    await waitFor(() => expect(store.getSnapshot().inserts.quickReply.action).toBe(whitespace))
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
    expect(summary).toHaveTextContent('input conditions')
    expect(summary).toHaveTextContent('Stops after this action')

    await user.click(within(actionList).getByRole('option', { name: /Do nothing/ }))
    const builtInSummary = screen.getByLabelText('Effective behavior')
    expect(builtInSummary).toHaveTextContent('Triggered by 2 voice phrases')
    expect(builtInSummary).toHaveTextContent('Performs no payload')
    expect(builtInSummary).toHaveTextContent('Uses built-in input conditions')
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
    expect(within(menu).getByRole('menuitem', { name: /Raw dictation/ })).toBeInTheDocument()
    expect(within(menu).getByRole('menuitem', { name: /^Language-model result/ })).toBeInTheDocument()
    expect(within(menu).getByRole('menuitem', { name: /Front app URL/ })).toBeInTheDocument()
    expect(within(menu).getByRole('menuitem', { name: /Recording folder path/ })).toBeInTheDocument()
    expect(within(menu).getByRole('menuitem', { name: /Action result/ })).toBeInTheDocument()
    expect(within(menu).queryByRole('menuitem', { name: /Uppercase/ })).not.toBeInTheDocument()
    expect(within(menu).queryByRole('menuitem', { name: /regex replacement/i })).not.toBeInTheDocument()
    expect(within(menu).getByRole('combobox', { name: 'Date format' })).toBeInTheDocument()
    await user.keyboard('{Escape}')

    const payload = screen.getByRole('textbox', { name: 'Insert payload' }) as HTMLTextAreaElement
    const placeholderStart = payload.value.indexOf('{{swResult}}')
    payload.focus()
    payload.setSelectionRange(placeholderStart + 2, placeholderStart + 2)
    fireEvent.select(payload)
    expect(screen.queryByRole('region', { name: 'Edit placeholder' })).not.toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: /1 placeholder found/ }))
    await user.click(within(screen.getByRole('listbox', { name: 'Placeholder occurrences' })).getByRole('option', { name: /Result/ }))
    expect(screen.getByRole('region', { name: 'Edit placeholder' })).toBeInTheDocument()
    expect(screen.getByRole('combobox', { name: 'Placeholder transform' })).toBeInTheDocument()
    expect(screen.getByRole('option', { name: 'Title case · French' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Placeholder syntax reference' })).toBeInTheDocument()
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
    await user.click(within(screen.getByRole('listbox', { name: 'Placeholder occurrences' })).getByRole('option', { name: /Result/ }))
    await user.click(screen.getByRole('button', { name: /Add replacement/ }))
    await user.type(screen.getByRole('textbox', { name: 'Find pattern 1' }), '||')
    await user.type(screen.getByRole('textbox', { name: 'Replacement text 1' }), '||')

    const expression = '{{swResult||\\|\\|||\\|\\|}}'
    expect(payload.value).toContain(expression)
  })

  it('preserves actual newlines in regex replacement stages for parser round-trips', async () => {
    const user = userEvent.setup()
    renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /quickReply/ }))

    const payload = screen.getByRole('textbox', { name: 'Insert payload' }) as HTMLTextAreaElement
    await user.click(screen.getByRole('button', { name: /1 placeholder found/ }))
    await user.click(within(screen.getByRole('listbox', { name: 'Placeholder occurrences' })).getByRole('option', { name: /Result/ }))
    await user.click(screen.getByRole('button', { name: /Add replacement/ }))
    fireEvent.change(screen.getByRole('textbox', { name: 'Find pattern 1' }), { target: { value: 'middle' } })
    fireEvent.change(screen.getByRole('textbox', { name: 'Replacement text 1' }), { target: { value: 'line 1\nline 2' } })

    const expression = '{{swResult||middle||line 1\nline 2}}'
    expect(payload.value).toContain(expression)
  })

  it('lists repeated and custom placeholders as independent occurrences without caret-driven expansion', async () => {
    const user = userEvent.setup()
    renderWithStore()
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('navigation', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /quickReply/ }))

    const payload = screen.getByRole('textbox', { name: 'Insert payload' }) as HTMLTextAreaElement
    fireEvent.change(payload, { target: { value: 'A {{swResult}} B {{swResult}} C {{custom.path::titleCase}} D {{xml:answer}}' } })
    expect(screen.queryByRole('region', { name: 'Edit placeholder' })).not.toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: /4 placeholders found/ }))
    const list = screen.getByRole('listbox', { name: 'Placeholder occurrences' })
    const resultOccurrences = within(list).getAllByRole('option', { name: /Result/ })
    expect(resultOccurrences).toHaveLength(2)
    await user.click(resultOccurrences[1])
    await user.selectOptions(screen.getByRole('combobox', { name: 'Placeholder transform' }), 'uppercase')
    expect(payload.value).toBe('A {{swResult}} B {{swResult::uppercase}} C {{custom.path::titleCase}} D {{xml:answer}}')

    await user.click(within(list).getByRole('option', { name: /custom\.path/ }))
    expect(screen.getByText('Metadata key or path preserved exactly.')).toBeInTheDocument()
    await user.selectOptions(screen.getByRole('combobox', { name: 'Placeholder transform' }), 'lowercase')
    expect(payload.value).toContain('{{custom.path::lowercase}}')
    expect(payload.value).toContain('{{xml:answer}}')

    await user.click(within(list).getByRole('option', { name: /Raw placeholder/ }))
    expect(screen.getByText(/visual inspector cannot safely rewrite/)).toBeInTheDocument()
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
    await user.click(within(screen.getByRole('listbox', { name: 'Placeholder occurrences' })).getByRole('option', { name: /Result/ }))
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
    await user.click(within(placeholderMenu).getByRole('menuitem', { name: /^Result .*\{\{swResult\}\}/ }))

    expect(payload).toHaveValue('{{swResult}}' + original)
    expect(payload).toHaveFocus()
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
