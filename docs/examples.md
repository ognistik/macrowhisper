# Examples

[← Documentation index](README.md) · [Configuration](configuration.md) · [Actions](actions.md)

## Config Examples

### Simple everyday config

```json
{
  "configVersion": 2,
  "defaults": {
    "watch": "~/superwhisper",
    "activeAction": "autoPaste",
    "actionDelay": 0,
    "returnDelay": 0.15,
    "restoreClipboard": true,
    "restoreClipboardDelay": 0.3,
    "scriptAsync": true,
    "scriptWaitTimeout": 3,
    "simReturn": false,
    "smartCasing": true,
    "smartPunctuation": true,
    "smartSpacing": true,
    "clipboardBuffer": 5,
    "clipboardStacking": false,
    "clipboardAttachments": false,
    "icon": "",
    "moveTo": "",
    "clipboardIgnore": "",
    "bypassModes": "",
    "nextAction": ""
  },
  "inserts": {
    "autoPaste": {
      "action": ".autoPaste",
      "icon": "•"
    },
    "emailWithDictatedLineBreaks": {
      "action": "Hey,\n\n{{swResult::ensureSentence||(?i)\\s*\\bline\\s*br(?:eak|eek|eik|iek|ick|ake)\\b[\\s.,;!?]*||\n||(?m)([^\\s.!?])(\\n+)||$1.$2||(?m)(\\n+)([a-z])||$1${2::uppercase}}}\n\nThanks,\nRobert",
      "triggerUrls": "mail.yahoo.com"
    }
  },
  "urls": {
    "google": {
      "action": "https://www.google.com/search?q={{swResult||\\.$||}}",
      "triggerVoice": "google|search",
      "triggerLogic": "or",
      "openWith": "Safari",
      "openBackground": false
    }
  },
  "shortcuts": {
    "Create Note": {
      "action": "{{swResult}}",
      "triggerVoice": "note"
    }
  },
  "scriptsShell": {
    "copyResult": {
      "action": "echo '{{swResult}}' | pbcopy",
      "triggerVoice": "copy result"
    }
  },
  "scriptsAS": {
    "notify": {
      "action": "display notification \"{{swResult}}\" with title \"Macrowhisper\"",
      "triggerVoice": "notify"
    }
  }
}
```

### Chained workflow example

In this example, the user dictates into an insert action, then a URL opens, then a notification appears.

```json
{
  "configVersion": 2,
  "defaults": {
    "watch": "~/superwhisper",
    "activeAction": "compose",
    "nextAction": "",
    "restoreClipboard": true,
    "moveTo": "~/Documents/SW-Processed"
  },
  "inserts": {
    "compose": {
      "action": "{{swResult}}",
      "inputCondition": "action|restoreClipboard",
      "nextAction": "searchDocs"
    }
  },
  "urls": {
    "searchDocs": {
      "action": "https://www.google.com/search?q={{swResult}}",
      "openBackground": true,
      "nextAction": "notifyDone"
    }
  },
  "scriptsAS": {
    "notifyDone": {
      "action": "display notification \"Done\" with title \"Macrowhisper\""
    }
  },
  "shortcuts": {},
  "scriptsShell": {}
}
```

### Custom transform pipeline

Use this pattern when the built-in placeholder transforms are not enough.

In this example:

- a shell action rewrites `{{swResult}}`
- `scriptAsync: false` makes Macrowhisper wait
- the script's output becomes available as `{{actionResult}}`
- the next insert action pastes the transformed result

```json
{
  "configVersion": 2,
  "defaults": {
    "watch": "~/superwhisper",
    "activeAction": "buildTicketPayload",
    "nextAction": "",
    "restoreClipboard": true
  },
  "inserts": {
    "insertTicketPayload": {
      "action": "## Ticket Draft\\n\\n{{actionResult}}\\n\\nSource App: {{frontApp}}"
    }
  },
  "urls": {},
  "shortcuts": {},
  "scriptsShell": {
    "buildTicketPayload": {
      "action": "TEXT='{{swResult}}'; CLEAN=$(printf \"%s\" \"$TEXT\" | tr '\\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ +| +$//g'); LEET_TEXT=$(printf \"%s\" \"$CLEAN\" | tr 'aeio' '4310'); printf \"Original: %s\\nTransformed: %s\\n\" \"$TEXT\" \"$LEET_TEXT\"",
      "scriptAsync": false,
      "scriptWaitTimeout": 3,
      "nextAction": "insertTicketPayload"
    }
  },
  "scriptsAS": {}
}
```

Notes:

- `{{actionResult}}` is the first synchronous script result in the current execution group
- if you chain several synchronous script-like steps, use `{{actionResult:0}}`, `{{actionResult:1}}`, and so on
- if the script fails or times out, the chain still continues, but `{{actionResult}}` may be empty

---
