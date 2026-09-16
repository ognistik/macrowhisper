import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { EditorStoreError } from '../model/types'
import type { Edit, Revision } from '../model/types'
import { API_SESSION_STORAGE_KEY, ApiStore, BOOTSTRAP_HEADER } from './apiStore'

const revision: Revision = { generation: 'daemon-1', version: 3, fingerprint: 'disk-3' }

function snapshotPayload(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    config: {
      configVersion: 2,
      defaults: {
        watch: '~/superwhisper',
        actionDelay: 0,
        history: null,
        simEsc: false,
        icon: '',
        activeAction: 'oldName',
      },
      inserts: {
        oldName: { action: '', nextAction: null, simEsc: false },
        other: { action: 'other', nextAction: 'oldName' },
      },
      urls: { open: { action: 'https://example.test', nextAction: 'oldName' } },
      shortcuts: {},
      scriptsShell: {},
      scriptsAS: {},
    },
    revision,
    configPath: '/tmp/macrowhisper.json',
    diskIsValid: true,
    isLegacyOnDisk: false,
    diskIssues: [],
    ...overrides,
  }
}

function jsonResponse(body: unknown, status = 200): Response {
  return {
    ok: status >= 200 && status < 300,
    status,
    statusText: status === 200 ? 'OK' : 'Error',
    json: async () => body,
  } as Response
}

function edit(path: string[], value: unknown): Edit {
  return { path, operation: 'set', value: value as Edit['value'] }
}

describe('ApiStore', () => {
  beforeEach(() => {
    window.history.replaceState(null, '', '/editor/')
    window.sessionStorage.clear()
    window.sessionStorage.setItem(API_SESSION_STORAGE_KEY, JSON.stringify({ sessionToken: 'stored-bearer', expiresAt: '2099-01-01T00:00:00.000Z' }))
  })

  afterEach(() => {
    vi.restoreAllMocks()
    window.sessionStorage.clear()
  })

  it('exchanges a fragment token, removes it immediately, and stores only the bearer in tab storage', async () => {
    window.history.replaceState(null, '', '/editor/#bootstrap=one-time-secret')
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({ sessionToken: 'bearer-secret', expiresAt: '2099-01-01T00:00:00.000Z' }))
      .mockResolvedValueOnce(jsonResponse(snapshotPayload()))

    const store = new ApiStore({ fetch: fetchMock, pollIntervalMs: 0 })
    expect(window.location.hash).toBe('')
    expect(store.getSnapshot().runtime.status).toBe('loading')
    await store.start()

    expect(fetchMock).toHaveBeenNthCalledWith(1, '/api/session', expect.objectContaining({
      method: 'POST',
      headers: expect.objectContaining({ [BOOTSTRAP_HEADER]: 'one-time-secret' }),
    }))
    expect(fetchMock.mock.calls[0][0].toString()).not.toContain('one-time-secret')
    expect(fetchMock.mock.calls[1][1]).toEqual(expect.objectContaining({
      headers: expect.objectContaining({ Authorization: 'Bearer bearer-secret' }),
    }))
    expect(JSON.parse(window.sessionStorage.getItem(API_SESSION_STORAGE_KEY) ?? '{}')).toMatchObject({ sessionToken: 'bearer-secret' })
    store.dispose()
  })

  it('loads a clean URL from the tab session and maps the daemon snapshot without coercing values', async () => {
    window.sessionStorage.setItem(API_SESSION_STORAGE_KEY, JSON.stringify({ sessionToken: 'stored-bearer', expiresAt: '2099-01-01T00:00:00.000Z' }))
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(snapshotPayload({
      diskIsValid: false,
      isLegacyOnDisk: true,
      diskIssues: [{ path: 'defaults.actionDelay', message: 'bad value', kind: 'semantic', rawValue: 'x' }],
    })))
    const store = new ApiStore({ fetch: fetchMock, pollIntervalMs: 0 })
    await store.start()

    const snapshot = store.getSnapshot()
    expect(fetchMock).toHaveBeenCalledWith('/api/config', expect.objectContaining({
      method: 'GET',
      headers: expect.objectContaining({ Authorization: 'Bearer stored-bearer' }),
    }))
    expect(snapshot.path).toBe('/tmp/macrowhisper.json')
    expect(snapshot.schemaVersion).toBe(2)
    expect(snapshot.defaults.actionDelay).toBe(0)
    expect(snapshot.defaults.history).toBeNull()
    expect(snapshot.defaults.simEsc).toBe(false)
    expect(snapshot.defaults.icon).toBe('')
    expect(snapshot.disk.status).toBe('invalid')
    expect(snapshot.disk.message).toBe('bad value')
    expect(snapshot.runtime.status).toBe('fallback')
    expect(snapshot.readOnly).toEqual([{ path: [], reason: expect.stringContaining('legacy') }])
    store.dispose()
  })

  it('uses the current revision and maps stable server errors to EditorStoreError', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse(snapshotPayload()))
      .mockResolvedValueOnce(jsonResponse({
        code: 'staleRevision',
        path: ['inserts', 'oldName', 'action'],
        message: 'The revision is stale.',
        issues: [],
      }, 409))
    const store = new ApiStore({ fetch: fetchMock, pollIntervalMs: 0 })
    await store.start()
    const request = store.request([edit(['inserts', 'oldName', 'action'], 'new')])
    await expect(store.mutate(request)).rejects.toMatchObject({
      code: 'stale',
      path: ['inserts', 'oldName', 'action'],
      message: 'The revision is stale.',
      request,
    })
    expect(JSON.parse(fetchMock.mock.calls[1][1].body as string)).toEqual({
      expectedRevision: revision,
      edits: request.edits,
    })
    expect(fetchMock.mock.calls[1][1].headers).toEqual(expect.objectContaining({
      Authorization: 'Bearer stored-bearer',
      'Content-Type': 'application/json',
    }))
    expect(store.getSnapshot().revision).toEqual(revision)
    store.dispose()
  })

  it('serializes mutations and sends null, false, zero, and empty values verbatim', async () => {
    const responses = [
      jsonResponse(snapshotPayload()),
      jsonResponse(snapshotPayload({ revision: { ...revision, version: 4, fingerprint: 'disk-4' } })),
      jsonResponse(snapshotPayload({ revision: { ...revision, version: 5, fingerprint: 'disk-5' } })),
    ]
    const fetchMock = vi.fn().mockImplementation(async () => responses.shift())
    const store = new ApiStore({ fetch: fetchMock, pollIntervalMs: 0 })
    await store.start()
    const first = store.mutate(store.request([
      edit(['defaults', 'actionDelay'], 0),
      edit(['defaults', 'history'], null),
      edit(['defaults', 'simEsc'], false),
      edit(['defaults', 'icon'], ''),
    ]))
    const second = store.mutate(store.request([edit(['defaults', 'returnDelay'], 0)]))
    await expect(Promise.all([first, second])).resolves.toHaveLength(2)
    expect(fetchMock.mock.calls[1][0]).toBe('/api/config/edits')
    expect(fetchMock.mock.calls[2][0]).toBe('/api/config/edits')
    expect(JSON.parse(fetchMock.mock.calls[1][1].body as string).edits).toEqual([
      { path: ['defaults', 'actionDelay'], operation: 'set', value: 0 },
      { path: ['defaults', 'history'], operation: 'set', value: null },
      { path: ['defaults', 'simEsc'], operation: 'set', value: false },
      { path: ['defaults', 'icon'], operation: 'set', value: '' },
    ])
    store.dispose()
  })

  it('renames an Insert and all inbound references in one atomic request', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse(snapshotPayload()))
      .mockResolvedValueOnce(jsonResponse(snapshotPayload({
        revision: { ...revision, version: 4, fingerprint: 'disk-4' },
      })))
    const store = new ApiStore({ fetch: fetchMock, pollIntervalMs: 0 })
    await store.start()

    await store.renameInsert('oldName', 'new.name')
    const body = JSON.parse(fetchMock.mock.calls[1][1].body as string) as { expectedRevision: Revision; edits: Edit[] }
    expect(body.expectedRevision).toEqual(revision)
    expect(body.edits).toEqual([
      { path: ['inserts', 'new.name'], operation: 'set', value: { action: '', nextAction: null, simEsc: false } },
      { path: ['inserts', 'other', 'nextAction'], operation: 'set', value: 'new.name' },
      { path: ['urls', 'open', 'nextAction'], operation: 'set', value: 'new.name' },
      { path: ['defaults', 'activeAction'], operation: 'set', value: 'new.name' },
      { path: ['inserts', 'oldName'], operation: 'remove' },
    ])
    store.dispose()
  })

  it('protects Inserts with inbound references before making a delete request', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(snapshotPayload()))
    const store = new ApiStore({ fetch: fetchMock, pollIntervalMs: 0 })
    await store.start()
    await expect(store.deleteInsert('oldName')).rejects.toBeInstanceOf(EditorStoreError)
    await expect(store.deleteInsert('oldName')).rejects.toMatchObject({ code: 'validation', path: ['inserts', 'oldName'] })
    expect(fetchMock).toHaveBeenCalledTimes(1)
    store.dispose()
  })

  it('reveals only the daemon-selected configuration through the authenticated bridge', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse(snapshotPayload()))
      .mockResolvedValueOnce(jsonResponse({ success: true }))
    const store = new ApiStore({ fetch: fetchMock, pollIntervalMs: 0 })
    await store.start()

    await expect(store.revealConfiguration()).resolves.toBeUndefined()
    expect(fetchMock).toHaveBeenNthCalledWith(2, '/api/config/reveal', expect.objectContaining({
      method: 'POST',
      headers: expect.objectContaining({
        Authorization: 'Bearer stored-bearer',
        'Content-Type': 'application/json',
      }),
    }))
    expect(fetchMock.mock.calls[1][1]).not.toHaveProperty('body')
    store.dispose()
  })

  it('starts and polls the authenticated native folder picker', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse(snapshotPayload()))
      .mockResolvedValueOnce(jsonResponse({ operationID: 'picker-1', status: 'pending', path: null }, 202))
      .mockResolvedValueOnce(jsonResponse({ operationID: 'picker-1', status: 'selected', path: '~/Documents/superwhisper' }))
    const store = new ApiStore({ fetch: fetchMock, pollIntervalMs: 0 })
    await store.start()

    await expect(store.chooseDirectory('watch')).resolves.toBe('~/Documents/superwhisper')
    expect(fetchMock).toHaveBeenNthCalledWith(2, '/api/folder-picker', expect.objectContaining({
      method: 'POST',
      headers: expect.objectContaining({
        Authorization: 'Bearer stored-bearer',
        'Content-Type': 'application/json',
      }),
      body: JSON.stringify({ purpose: 'watch' }),
    }))
    expect(fetchMock).toHaveBeenNthCalledWith(3, '/api/folder-picker/picker-1', expect.objectContaining({
      method: 'GET',
      headers: expect.objectContaining({ Authorization: 'Bearer stored-bearer' }),
    }))
    store.dispose()
  })

  it('treats folder-picker cancellation as a normal empty selection', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse(snapshotPayload()))
      .mockResolvedValueOnce(jsonResponse({ operationID: 'picker-2', status: 'pending', path: null }, 202))
      .mockResolvedValueOnce(jsonResponse({ operationID: 'picker-2', status: 'cancelled', path: null }))
    const store = new ApiStore({ fetch: fetchMock, pollIntervalMs: 0 })
    await store.start()
    await expect(store.chooseDirectory('moveTo')).resolves.toBeNull()
    store.dispose()
  })
})
