import { describe, expect, it } from 'vitest'
import {
  analyzeTriggerExpression,
  serializeTriggerTokens,
  serializeVoiceRegex,
  triggerRegexPatternWarning,
} from './triggerExpression'

describe('trigger expression editing', () => {
  it('reads harmless empty separators without changing their saved bytes', () => {
    const analysis = analyzeTriggerExpression('|reply||*respond|', 'triggerVoice')

    expect(analysis).toMatchObject({
      kind: 'tokens',
      canonical: 'reply|*respond',
      normalized: true,
      rows: [
        { value: 'reply', excluded: false, placement: 'beginning' },
        { value: 'respond', excluded: false, placement: 'end' },
      ],
    })
  })

  it('keeps pipes inside a voice regular expression intact', () => {
    expect(analyzeTriggerExpression('!==^(reply|respond)$==', 'triggerVoice')).toEqual({
      kind: 'tokens',
      rows: [{ kind: 'regex', value: '^(reply|respond)$', excluded: true }],
      canonical: '!==^(reply|respond)$==',
      normalized: false,
    })
  })

  it('reads mixed literal and raw-regex voice rows in order', () => {
    expect(analyzeTriggerExpression('reply|!==^(cancel|stop)$==|!*title', 'triggerVoice')).toEqual({
      kind: 'tokens',
      rows: [
        { value: 'reply', excluded: false, placement: 'beginning' },
        { kind: 'regex', value: '^(cancel|stop)$', excluded: true },
        { value: 'title', excluded: true, placement: 'end' },
      ],
      canonical: 'reply|!==^(cancel|stop)$==|!*title',
      normalized: false,
    })
  })

  it('serializes visual rows without exposing syntax markers', () => {
    expect(serializeTriggerTokens([
      { value: ' reply ', excluded: false, placement: 'beginning' },
      { value: 'respond', excluded: true, placement: 'end' },
      { value: ' ', excluded: false, placement: 'beginning' },
    ], 'triggerVoice')).toBe('reply|!*respond')
    expect(serializeVoiceRegex('^(reply|respond)$', true)).toBe('!==^(reply|respond)$==')
    expect(serializeTriggerTokens([
      { value: 'reply', excluded: false, placement: 'beginning' },
      { kind: 'regex', value: '^(cancel|stop)$', excluded: true },
      { kind: 'regex', value: '   ', excluded: false },
      { value: 'title', excluded: true, placement: 'end' },
    ], 'triggerVoice')).toBe('reply|!==^(cancel|stop)$==|!*title')
  })

  it('reserves recovery for values the visual editor cannot represent safely', () => {
    expect(analyzeTriggerExpression('==unclosed', 'triggerVoice')).toEqual({ kind: 'unreadable', raw: '==unclosed' })
    expect(analyzeTriggerExpression('reply|==unclosed|title', 'triggerVoice')).toEqual({ kind: 'unreadable', raw: 'reply|==unclosed|title' })
    expect(analyzeTriggerExpression('reply==literal==', 'triggerVoice')).toEqual({ kind: 'unreadable', raw: 'reply==literal==' })
    expect(analyzeTriggerExpression('====', 'triggerVoice')).toEqual({ kind: 'unreadable', raw: '====' })
    expect(analyzeTriggerExpression('|||', 'triggerApps')).toEqual({ kind: 'unreadable', raw: '|||' })
    expect(analyzeTriggerExpression('!|', 'triggerVoice')).toEqual({ kind: 'unreadable', raw: '!|' })
  })

  it('provides a lightweight inline regex check', () => {
    expect(triggerRegexPatternWarning('(?i)^(reply|respond)$')).toBeNull()
    expect(triggerRegexPatternWarning('(')).toMatch(/could not be checked/i)
    expect(triggerRegexPatternWarning('')).toBeNull()
  })
})
