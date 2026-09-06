import { describe, expect, it, vi } from 'vitest'
import { createFixtureSnapshot } from '../fixtures'
import type { Edit, InsertConfig } from '../model/types'
import { EditorStoreError, isEditorStoreError } from '../model/types'
import { FixtureStore } from './fixtureStore'

const edit = (path: string[], value: unknown): Edit => ({
  path,
  operation: 'set',
  value: value as Edit['value'],
})

const insert = (action: string): InsertConfig => ({ action, triggerLogic: 'or' })

describe('fixture configuration snapshots', () => {
  it('keeps the populated fixture valid and confines brokenLink to invalid', () => {
    expect(createFixtureSnapshot('populated').inserts).not.toHaveProperty('brokenLink')
    expect(createFixtureSnapshot('empty').defaults.activeAction).toBe('')
    expect(createFixtureSnapshot('invalid').inserts.brokenLink.nextAction).toBe('does-not-exist')
  })
})

describe('FixtureStore transactions', () => {
  it('preserves explicit null, false, zero, and empty string values', async () => {
    const store = new FixtureStore()
    const result = await store.mutate(store.request([
      edit(['defaults', 'actionDelay'], 0),
      edit(['defaults', 'history'], null),
      edit(['defaults', 'simEsc'], false),
      edit(['defaults', 'icon'], ''),
    ]))

    expect(result.snapshot.defaults.actionDelay).toBe(0)
    expect(result.snapshot.defaults.history).toBeNull()
    expect(result.snapshot.defaults.simEsc).toBe(false)
    expect(result.snapshot.defaults.icon).toBe('')
  })

  it('rejects malformed candidates atomically', async () => {
    const store = new FixtureStore()
    const before = store.getSnapshot()

    await expect(store.mutate(store.request([edit(['defaults', 'actionDelay'], -1)])))
      .rejects.toMatchObject({ code: 'validation', path: ['defaults', 'actionDelay'] })
    await expect(store.mutate(store.request([edit(['defaults', 'history'], 1.5)])))
      .rejects.toMatchObject({ code: 'validation', path: ['defaults', 'history'] })
    await expect(store.mutate(store.request([edit(['inserts', 'quickReply', 'inputCondition'], 'simEsc||action')])))
      .rejects.toMatchObject({ code: 'validation', path: ['inserts', 'quickReply', 'inputCondition'] })
    await expect(store.mutate(store.request([edit(['inserts', 'quickReply', 'nextAction'], 'missing')])))
      .rejects.toMatchObject({ code: 'validation', path: ['inserts', 'quickReply', 'nextAction'] })

    const after = store.getSnapshot()
    expect(after.revision).toEqual(before.revision)
    expect(after.inserts.quickReply.nextAction).toBe('')
  })

  it('validates duplicate names and cycles across every action group', async () => {
    const store = new FixtureStore()
    const duplicate = store.request([
      { path: ['inserts', 'same'], operation: 'set', value: insert('one') as unknown as Edit['value'] },
      { path: ['urls', 'same'], operation: 'set', value: insert('two') as unknown as Edit['value'] },
    ])
    await expect(store.mutate(duplicate)).rejects.toMatchObject({ code: 'validation', path: ['urls', 'same'] })
    expect(store.getSnapshot().inserts).not.toHaveProperty('same')

    const cycle = store.request([
      edit(['inserts', 'quickReply', 'nextAction'], 'dailyNotes'),
      edit(['inserts', 'dailyNotes', 'nextAction'], 'quickReply'),
    ])
    await expect(store.mutate(cycle)).rejects.toMatchObject({ code: 'validation' })
    expect(store.getSnapshot().inserts.quickReply.nextAction).toBe('')
  })

  it('treats dotted and prototype-looking action names as literal path segments', async () => {
    const store = new FixtureStore()
    await store.createInsert('name.with.dots', insert('payload'))
    await store.createInsert('__proto__', insert('safe payload'))

    expect(store.getSnapshot().inserts['name.with.dots'].action).toBe('payload')
    expect(store.getSnapshot().inserts['__proto__'].action).toBe('safe payload')
    expect(({} as Record<string, unknown>).polluted).toBeUndefined()

    await store.renameInsert('name.with.dots', 'renamed.with.dots')
    expect(store.getSnapshot().inserts).not.toHaveProperty('name.with.dots')
    expect(store.getSnapshot().inserts['renamed.with.dots'].action).toBe('payload')
  })

  it('renames references in one transaction and guards deletion references', async () => {
    const store = new FixtureStore()
    await store.mutate(store.request([
      edit(['defaults', 'nextAction'], 'dailyNotes'),
      edit(['inserts', 'quickReply', 'nextAction'], 'dailyNotes'),
    ]))

    const renamed = await store.renameInsert('dailyNotes', 'notes.with.dots')
    expect(renamed.snapshot.defaults.nextAction).toBe('notes.with.dots')
    expect(renamed.snapshot.inserts.quickReply.nextAction).toBe('notes.with.dots')
    expect(renamed.snapshot.inserts['notes.with.dots']).toBeDefined()
    expect(renamed.snapshot.inserts.dailyNotes).toBeUndefined()

    await expect(store.deleteInsert('notes.with.dots')).rejects.toMatchObject({ code: 'validation', path: ['inserts', 'notes.with.dots'] })
    await store.mutate(store.request([
      edit(['defaults', 'nextAction'], ''),
      edit(['inserts', 'quickReply', 'nextAction'], ''),
    ]))
    await store.deleteInsert('notes.with.dots')
    expect(store.getSnapshot().inserts['notes.with.dots']).toBeUndefined()
  })

  it('serializes same-tab field writes but rejects writes after an external change', async () => {
    const store = new FixtureStore({ writeDelayMs: 1 })
    const first = store.mutate(store.request([edit(['defaults', 'actionDelay'], 0.1)]))
    const second = store.mutate(store.request([edit(['defaults', 'returnDelay'], 0)]))
    await expect(Promise.all([first, second])).resolves.toHaveLength(2)
    expect(store.getSnapshot().defaults.actionDelay).toBe(0.1)
    expect(store.getSnapshot().defaults.returnDelay).toBe(0)

    const staleRequest = store.request([edit(['defaults', 'simEsc'], false)])
    store.simulateExternalChange(edit(['defaults', 'simEsc'], true))
    await expect(store.mutate(staleRequest)).rejects.toMatchObject({ code: 'stale' })
    expect(store.getSnapshot().defaults.simEsc).toBe(true)
  })

  it('makes the conflict scenario recoverable after an explicit fresh-revision reapply', async () => {
    const store = new FixtureStore('conflict')
    const before = store.getSnapshot()
    const request = store.request([edit(['inserts', 'quickReply', 'action'], 'My deliberate reply')])

    await expect(store.mutate(request)).rejects.toMatchObject({ code: 'conflict' })
    const afterConflict = store.getSnapshot()
    expect(afterConflict.revision.version).toBe(before.revision.version + 1)
    expect(afterConflict.inserts.quickReply.action).not.toBe(before.inserts.quickReply.action)

    // The request captured before the remote write is still stale and cannot
    // silently replay over that newer content.
    await expect(store.mutate(request)).rejects.toMatchObject({ code: 'stale' })

    const freshRequest = store.request([edit(['inserts', 'quickReply', 'action'], 'My deliberate reply')])
    const result = await store.mutate(freshRequest)
    expect(result.snapshot.inserts.quickReply.action).toBe('My deliberate reply')
    expect(result.snapshot.revision.version).toBe(afterConflict.revision.version + 1)
  })

  it('does not publish failed writes and can reconnect or retry', async () => {
    const listener = vi.fn()
    const store = new FixtureStore({ failWrites: true, failureMessage: 'fixture disk full' })
    store.subscribe(listener)
    const request = store.request([edit(['defaults', 'actionDelay'], 0.2)])
    await expect(store.mutate(request)).rejects.toMatchObject({ code: 'persistence', message: 'fixture disk full' })
    expect(listener).not.toHaveBeenCalled()
    expect(store.getSnapshot().defaults.actionDelay).toBe(0)

    store.setFailWrites(false)
    await store.mutate(request)
    expect(store.getSnapshot().defaults.actionDelay).toBe(0.2)

    const disconnected = new FixtureStore('disconnected')
    const disconnectedRequest = disconnected.request([edit(['defaults', 'simEsc'], false)])
    await expect(disconnected.mutate(disconnectedRequest)).rejects.toMatchObject({ code: 'disconnected' })
    expect(disconnected.reconnect().runtime.status).toBe('connected')
    await expect(disconnected.mutate(disconnectedRequest)).rejects.toMatchObject({ code: 'stale' })
  })

  it('exposes stable error type checks', async () => {
    const store = new FixtureStore()
    try {
      await store.mutate(store.request([edit(['defaults', 'actionDelay'], -1)]))
    } catch (error) {
      expect(error).toBeInstanceOf(EditorStoreError)
      expect(isEditorStoreError(error, 'validation')).toBe(true)
      return
    }
    throw new Error('expected a validation error')
  })
})
