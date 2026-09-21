export const triggerFields = ['triggerVoice', 'triggerApps', 'triggerModes', 'triggerUrls'] as const

export type TriggerField = typeof triggerFields[number]
export type VoicePhrasePlacement = 'beginning' | 'end'

export interface TriggerToken {
  value: string
  excluded: boolean
  placement?: VoicePhrasePlacement
  /** Raw voice-regex rows do not have phrase placement semantics. */
  kind?: 'regex'
}

export type TriggerExpressionAnalysis =
  | { kind: 'tokens'; rows: TriggerToken[]; canonical: string; normalized: boolean }
  | { kind: 'unreadable'; raw: string }

interface SplitResult {
  tokens: string[]
  balanced: boolean
}

function splitVoiceTriggerTokens(raw: string): SplitResult {
  const tokens: string[] = []
  let token = ''
  let inRegex = false

  for (let index = 0; index < raw.length;) {
    if (raw.startsWith('==', index)) {
      inRegex = !inRegex
      token += '=='
      index += 2
      continue
    }
    if (raw[index] === '|' && !inRegex) {
      tokens.push(token)
      token = ''
      index += 1
      continue
    }
    token += raw[index]
    index += 1
  }
  tokens.push(token)
  return { tokens, balanced: !inRegex }
}

function rawRegexParts(token: string): { body: string; excluded: boolean } | null {
  const excluded = token.startsWith('!')
  const candidate = excluded ? token.slice(1) : token
  if (!candidate.startsWith('==') || !candidate.endsWith('==') || candidate.length < 4) return null
  return { body: candidate.slice(2, -2), excluded }
}

export function serializeVoiceRegex(body: string, excluded = false): string {
  return `${excluded ? '!' : ''}==${body}==`
}

export function serializeTriggerTokens(tokens: TriggerToken[], field: TriggerField): string {
  return tokens
    .map((token) => ({
      ...token,
      // Keep regex bodies byte-for-byte intact; whitespace around literal
      // rows is editor noise, while whitespace inside a regex is meaningful.
      value: field === 'triggerVoice' && token.kind === 'regex' ? token.value : token.value.trim(),
    }))
    .filter((token) => token.value.trim() !== '')
    .map((token) => {
      if (field === 'triggerVoice' && token.kind === 'regex') {
        return serializeVoiceRegex(token.value, token.excluded)
      }
      const suffix = field === 'triggerVoice' && token.placement === 'end'
      return `${token.excluded ? '!' : ''}${suffix ? '*' : ''}${token.value}`
    })
    .join('|')
}

export function analyzeTriggerExpression(raw: string, field: TriggerField): TriggerExpressionAnalysis {
  if (raw.trim() === '') return { kind: 'tokens', rows: [], canonical: '', normalized: raw !== '' }

  const split = field === 'triggerVoice'
    ? splitVoiceTriggerTokens(raw)
    : { tokens: raw.split('|'), balanced: true }
  if (!split.balanced) return { kind: 'unreadable', raw }

  const meaningfulTokens = split.tokens.map((token) => token.trim()).filter(Boolean)
  // A nonempty serialized value made only from separators has runtime-specific
  // catch-all behavior. Do not silently turn it into an unconfigured trigger.
  if (meaningfulTokens.length === 0) return { kind: 'unreadable', raw }

  if (field === 'triggerVoice') {
    const regexTokens = meaningfulTokens.map(rawRegexParts)
    const regexCount = regexTokens.filter(Boolean).length
    // A wrapper marker that is not the complete token form cannot be shown
    // safely as a literal row. Unbalanced wrappers are handled above by the
    // splitter; this also catches balanced-but-misplaced markers such as
    // `phrase==pattern==`.
    if (meaningfulTokens.some((token, index) => token.includes('==') && !regexTokens[index])) {
      return { kind: 'unreadable', raw }
    }
    if (regexCount > 0 && regexTokens.some((regex) => regex && !regex.body.trim())) return { kind: 'unreadable', raw }
  }

  const rows: TriggerToken[] = []
  for (const serializedToken of meaningfulTokens) {
    const regex = field === 'triggerVoice' ? rawRegexParts(serializedToken) : null
    if (regex) {
      if (!regex.body.trim()) return { kind: 'unreadable', raw }
      rows.push({ kind: 'regex', value: regex.body, excluded: regex.excluded })
      continue
    }
    const excluded = serializedToken.startsWith('!')
    const withoutException = excluded ? serializedToken.slice(1) : serializedToken
    const suffix = field === 'triggerVoice' && withoutException.startsWith('*')
    const value = (suffix ? withoutException.slice(1) : withoutException).trim()
    if (!value) return { kind: 'unreadable', raw }
    rows.push({
      excluded,
      value,
      ...(field === 'triggerVoice' ? { placement: suffix ? 'end' as const : 'beginning' as const } : {}),
    })
  }

  const canonical = serializeTriggerTokens(rows, field)
  return { kind: 'tokens', rows, canonical, normalized: canonical !== raw }
}

export function triggerRegexPatternWarning(pattern: string): string | null {
  if (!pattern.trim()) return null
  // Apple regular expressions accept leading case-mode groups that JavaScript
  // does not. Remove the documented forms before this lightweight browser
  // syntax check; the Macrowhisper runtime remains authoritative.
  const browserPattern = pattern.replace(/^\(\?(?:i|-i)\)/, '')
  try {
    new RegExp(browserPattern)
    return null
  } catch {
    return 'This expression could not be checked in the browser. Review its brackets and escapes before continuing.'
  }
}
