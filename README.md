# Macrowhisper

**A powerful automation helper app for [Superwhisper](https://superwhisper.com/?via=robert)**

[![Swift Version](https://img.shields.io/badge/Swift-6.1.2-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-macOS-blue.svg)](https://www.apple.com/macos/)
[![License](https://img.shields.io/badge/License-GMT-blue.svg)](LICENSE)

---
## What It Does
Macrowhisper monitors your Superwhisper recordings and executes intelligent automated actions based on configurable rules.

### Key Features
- ****🎙️ Voice-Triggered Automations****: Execute actions based on voice patterns or keywords
- ****🧠 Intelligent Trigger System****: Advanced pattern matching for applications and Superwhisper active mode
- ****📝 Multiple Action Types****: Text insertion, URL opening, shell scripts, AppleScript, and macOS Shortcuts
- ****⚙️ Service Integration****: Run as background service as a launch agent
- ****🔄 Live Configuration****: JSON-based configuration with real-time reloading
- ****🗂️ History Management****: Automatic cleanup of old recordings
- ****🔌 CLI Interface****: Comprehensive command-line interface which allows for easy integration with automation apps

---
## Learn More
**💫 [Check the full docs and sample use cases](https://by.afadingthought.com/macrowhisper)**

---
## Quick Start

### Install
```bash
brew install ognistik/formulae/macrowhisper
```

Or you can insall via a script:
```bash
# Installs Macrowhisper's binary in /usr/local/bin
curl -L https://raw.githubusercontent.com/ognistik/macrowhisper/main/scripts/install.sh | sudo sh
```

### Configure & Start
```bash
# Reveal/create configuration file
# By default auto-created at ~/.config/macrowhisper/macrowhisper.json
macrowhisper --reveal-config

# Start background service
macrowhisper --start-service
```

### Essential Superwhisper Settings
To prevent conflicts between the two apps:
- **Turn OFF**: Paste Result Text, Restore Clipboard After Paste, Simulate Key Presses
- **Keep ON**: Recording Window

### Test Your Setup
After granting accessibility permissions, test dictation in different apps. By default, Macrowhisper mimics Superwhisper's auto-paste behavior.

---
## Key Commands

```bash
# Service Management
macrowhisper --start-service        # Start background service
macrowhisper --stop-service         # Stop service
macrowhisper --uninstall-service    # Uninstall service
macrowhisper --service-status       # Check service status

# Configuration
macrowhisper --reveal-config        # Open config file
macrowhisper --set-config <path>    # Set custom config location

# Actions
macrowhisper --action <name>        # Set active action
macrowhisper --exec-action <name>   # Execute action with last result
macrowhisper --add-insert <name>    # Add new insert action
macrowhisper --add-url <name>       # Add URL action
macrowhisper --add-shell <name>     # Add shell script action
macrowhisper --add-shortcut <name>  # Add macOS Shortcut action
macrowhisper --add-as <name>        # Add AppleScript action

# Status & Help
macrowhisper --status               # Show running status
macrowhisper --help                 # Full command list
```

---
## How It Works
1. **Monitor**: Watches your Superwhisper recordings folder
2. **Evaluate**: Checks triggers (voice patterns, active app, Superwhisper mode)
3. **Execute**: Runs matching actions (paste text, open URLs, run scripts, etc.)

---
## Configuration Example
Macrowhisper uses JSON configuration with dynamic placeholders:

```json
{
  "defaults": {
    "activeAction": "autoPaste",
    "pressReturn": false,
    "actionDelay": 0.0
  },
  "inserts": {
    "autoPaste": {
      "action": "{{swResult}}"
    }
  },
  "urls": {
    "googleSearch": {
      "action": "https://www.google.com/search?q={{swResult}}",
      "triggerVoice": "ask google|search online"
    }
  }
}
```

**Available Placeholders:**
- `{{swResult}}` - Your transcription result
- `{{metaKeyName}}` - Any key from Superwhisper's meta.json file
- `{{frontApp}}` - Expands to your application
- `{{date:yyyy-MM-dd}}` - Formatted dates
- `{{xml:tagname}}` - Extract XML content from LLM results
- Plus regex replacements and contextual escaping

**[Sample Configuration File](https://github.com/ognistik/macrowhisper/blob/main/samples/macrowhisper.json)**  
*Make sure to run `macrowhisper --restart-service` if you set this as your default config.*

---
## Project Structure
This is a Swift-based CLI application with the following architecture:

```
src/macrowhisper/
├── main.swift                   # CLI interface & app entry
├── Config/                      # Configuration management
├── Watcher/                     # File system monitoring
├── Utils/                       # Core utilities & action execution
├── Networking/                  # Socket communication & updates
└── History/                     # Recording cleanup
```

[Codebase Map](https://github.com/ognistik/macrowhisper/blob/main/src/CODEBASE_MAP.md)  
[The Processing Flow](https://github.com/ognistik/macrowhisper/blob/main/src/PROCESSING_FLOW.md)

---
## Contributing
This project is open source and welcomes contributions! 

- **Source code**: All project files are in the `src/` directory
- **Issues & PRs**: Use GitHub's issue tracker and pull request system

Whether you're fixing bugs, adding features, improving documentation, or sharing creative use cases, your contributions help make Macrowhisper better for everyone.

---
## Documentation

This README covers the basics. For comprehensive documentation including:
- Advanced trigger system and logic
- Complete settings reference  
- Automation examples and workflows
- Troubleshooting and debugging
- Integration with Keyboard Maestro and automation apps

**📖 Visit the full documentation: [by.afadingthought.com/macrowhisper](https://by.afadingthought.com/macrowhisper)**

---
## Support
If you find Macrowhisper useful, consider supporting its development:
**☕ [Buy me a coffee](https://buymeacoffee.com/afadingthought/)**

This is an open source project with no monetization. Your support helps cover development costs and keeps the project active.

---
*Macrowhisper is an independent project and is not affiliated with Superwhisper.* 