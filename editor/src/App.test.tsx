import { act, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import App, { defaultFieldGroups, overrideFields } from './App'
import { defaultsSchema, insertSchema } from './generated/schema'
import { FixtureStore } from './store/fixtureStore'
import type { StoreScenario } from './model/types'

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
  await waitFor(() => expect(screen.getAllByText('Saved').length).toBeGreaterThan(0))
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

  it('keeps root null meanings distinct and serializes rapid field changes', async () => {
    const user = userEvent.setup()
    render(<App />)

    const fallback = screen.getByRole('combobox', { name: 'Fallback action' })
    expect(within(fallback).getByRole('option', { name: 'None (null)' })).toBeInTheDocument()
    expect(within(fallback).getByRole('option', { name: 'None (empty)' })).toBeInTheDocument()
    expect(within(fallback).queryByRole('option', { name: 'Use built-in (autoPaste)' })).not.toBeInTheDocument()

    await user.selectOptions(fallback, 'quickReply')
    const notifications = screen.getByRole('combobox', { name: 'System notifications' })
    const updates = screen.getByRole('combobox', { name: 'Automatic update checks' })
    // Both writes start from the same visible revision. The editor queues the
    // second write against the first result instead of surfacing a stale error.
    await user.selectOptions(notifications, 'on')
    await user.selectOptions(updates, 'on')
    await screen.findByText('Saved', {}, { timeout: 1500 })
    expect(fallback).toHaveValue('quickReply')
    expect(notifications).toHaveValue('on')
    expect(updates).toHaveValue('on')
    expect(within(updates).getByRole('option', { name: 'Use built-in (Allow checks)' })).toBeInTheDocument()
  })

  it('opens the populated Insert editor and exposes only valid trigger logic choices', async () => {
    const user = userEvent.setup()
    render(<App />)

    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))

    const actionList = screen.getByRole('complementary', { name: 'Insert actions' })
    const firstInsert = within(actionList).getByRole('option', { name: /autoPaste/ })
    expect(firstInsert).toHaveAttribute('aria-selected', 'true')
    expect(screen.getByRole('heading', { name: 'autoPaste' })).toBeInTheDocument()
    expect(screen.queryByRole('heading', { name: 'No Inserts yet' })).not.toBeInTheDocument()

    const logic = screen.getByRole('combobox', { name: 'Trigger logic' })
    expect(within(logic).getByRole('option', { name: 'Default (Any OR)' })).toBeInTheDocument()
    expect(within(logic).getByRole('option', { name: 'Any (OR)' })).toBeInTheDocument()
    expect(within(logic).getByRole('option', { name: 'All (AND)' })).toBeInTheDocument()
    expect(within(logic).queryByRole('option', { name: /explicit empty/ })).not.toBeInTheDocument()
  })

  it('inserts a placeholder at the saved caret while keeping the payload toolbar composite', async () => {
    const user = userEvent.setup()
    render(<App />)
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('complementary', { name: 'Insert actions' })
    await user.click(within(actionList).getByRole('option', { name: /quickReply/ }))

    const payload = screen.getByRole('textbox', { name: 'Insert payload' }) as HTMLTextAreaElement
    const original = payload.value
    payload.focus()
    payload.setSelectionRange(0, 0)
    await user.click(screen.getByRole('button', { name: /Insert placeholder/ }))
    const placeholderMenu = screen.getByRole('menu', { name: 'Insert placeholder' })
    await user.click(within(placeholderMenu).getByRole('menuitem', { name: /^\{\{swResult\}\}/ }))

    expect(payload).toHaveValue('{{swResult}}' + original)
    expect(payload).toHaveFocus()
    // Moving to another editor section commits once, after the toolbar menu
    // has finished, instead of saving the pre-insertion value on blur.
    await user.click(screen.getByRole('heading', { name: 'Payload' }))
    await screen.findByText('Saved', {}, { timeout: 1500 })
    expect(payload).toHaveValue('{{swResult}}' + original)
  })

  it('uses a native modal dialog with focus restoration for deletion confirmation', async () => {
    const user = userEvent.setup()
    render(<App />)
    const navigation = screen.getByRole('navigation', { name: 'Configuration sections' })
    await user.click(within(navigation).getByRole('button', { name: /^Inserts/ }))
    const actionList = screen.getByRole('complementary', { name: 'Insert actions' })
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

  it('makes the mobile navigation modal and returns focus to its menu button', async () => {
    installMediaQuery(true)
    const user = userEvent.setup()
    render(<App />)
    const menu = screen.getByRole('button', { name: /Menu/ })
    await user.click(menu)

    const sidebar = screen.getByRole('dialog', { name: 'Configuration navigation' })
    expect(sidebar).toHaveAttribute('aria-modal', 'true')
    expect(sidebar).not.toHaveAttribute('aria-hidden', 'true')
    await user.keyboard('{Escape}')
    expect(screen.queryByRole('dialog', { name: 'Configuration navigation' })).not.toBeInTheDocument()
    expect(menu).toHaveFocus()
  })

  it('acknowledges a choice immediately and persists the selected value', async () => {
    const user = userEvent.setup()
    const store = renderWithStore('populated', 35)
    const control = screen.getByRole('combobox', { name: 'Simulate Escape' })

    await user.selectOptions(control, 'off')

    await waitFor(() => expect(screen.getAllByText('Saving…').length).toBeGreaterThan(0))
    await waitFor(() => expect(store.getSnapshot().defaults.simEsc).toBe(false), { timeout: 1000 })
    await waitForSaved()
    expect(control).toHaveValue('off')
  })

  it('keeps text edits local until the control blurs', async () => {
    const user = userEvent.setup()
    const store = renderWithStore()
    const control = screen.getByRole('textbox', { name: 'Watch folder' })
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
    const watch = screen.getByRole('textbox', { name: 'Watch folder' })
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
    const actionList = screen.getByRole('complementary', { name: 'Insert actions' })
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
