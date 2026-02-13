import Foundation
import Cocoa

/// Handles execution of different action types
class ActionExecutor {
    private let logger: Logger
    private let socketCommunication: SocketCommunication
    private let configManager: ConfigurationManager
    private let clipboardMonitor: ClipboardMonitor
    
    init(logger: Logger, socketCommunication: SocketCommunication, configManager: ConfigurationManager, clipboardMonitor: ClipboardMonitor) {
        self.logger = logger
        self.socketCommunication = socketCommunication
        self.configManager = configManager
        self.clipboardMonitor = clipboardMonitor
    }

    struct ChainExecutionResult {
        let success: Bool
        let finalActionName: String?
        let finalActionType: ActionType?
        let finalAction: Any?
        let errorMessage: String?
    }

    private struct ResolvedActionStep {
        let action: Any
        let name: String
        let type: ActionType
    }

    private struct StepExecutionOptions {
        let isFirstInChain: Bool
        let isLastInChain: Bool
    }

    private struct ChainRuntimeState {
        let currentStep: ResolvedActionStep
        let visited: Set<String>
        let firstInsertActionName: String?
        let cachedInputFieldState: Bool?
        let stepNumber: Int
        let isFirstStep: Bool
    }
    
    /// Executes an action based on its type (single-step compatibility wrapper).
    func executeAction(
        action: Any,
        name: String,
        type: ActionType,
        metaJson: [String: Any],
        recordingPath: String,
        isTriggeredAction: Bool = true,  // Default to true since this is typically called for trigger actions
        onCompletion: (() -> Void)? = nil
    ) {
        executeActionChain(
            initialAction: action,
            name: name,
            type: type,
            metaJson: metaJson,
            recordingPath: recordingPath,
            isTriggeredAction: isTriggeredAction
        ) { _ in
            onCompletion?()
        }
    }

    func executeActionChain(
        initialAction: Any,
        name: String,
        type: ActionType,
        metaJson: [String: Any],
        recordingPath: String,
        isTriggeredAction: Bool = true,
        onCompletion: ((ChainExecutionResult) -> Void)? = nil
    ) {
        let initialStep = ResolvedActionStep(action: initialAction, name: name, type: type)
        let initialState = ChainRuntimeState(
            currentStep: initialStep,
            visited: [],
            firstInsertActionName: nil,
            cachedInputFieldState: nil,
            stepNumber: 1,
            isFirstStep: true
        )
        executeActionChainStep(
            state: initialState,
            metaJson: metaJson,
            recordingPath: recordingPath,
            isTriggeredAction: isTriggeredAction,
            onCompletion: onCompletion
        )
    }

    private func executeActionChainStep(
        state: ChainRuntimeState,
        metaJson: [String: Any],
        recordingPath: String,
        isTriggeredAction: Bool,
        onCompletion: ((ChainExecutionResult) -> Void)?
    ) {
        do {
            if state.visited.contains(state.currentStep.name) {
                throw ActionChainError.cycleDetected(state.currentStep.name)
            }

            var nextVisited = state.visited
            nextVisited.insert(state.currentStep.name)

            var nextFirstInsertActionName = state.firstInsertActionName
            if state.currentStep.type == .insert {
                if let first = nextFirstInsertActionName, first != state.currentStep.name {
                    throw ActionChainError.multipleInsertActions(first: first, second: state.currentStep.name)
                }
                nextFirstInsertActionName = state.currentStep.name
            }

            let (executionStep, cachedInputState) = resolveStepForExecution(
                step: state.currentStep,
                cachedInputFieldState: state.cachedInputFieldState
            )

            let nextActionName = getEffectiveNextActionName(
                for: executionStep.action,
                actionName: executionStep.name,
                type: executionStep.type,
                isFirstStep: state.isFirstStep
            )
            let nextStep: ResolvedActionStep?
            if let nextActionName, !nextActionName.isEmpty {
                guard let next = try findUniqueActionByName(nextActionName) else {
                    throw ActionChainError.missingAction(nextActionName)
                }
                nextStep = ResolvedActionStep(action: next.action, name: next.name, type: next.type)
            } else {
                nextStep = nil
            }

            let options = StepExecutionOptions(
                isFirstInChain: state.isFirstStep,
                isLastInChain: nextStep == nil
            )

            logInfo("[ActionChain] Executing action '\(executionStep.name)' (step \(state.stepNumber), type: \(executionStep.type))")
            executeResolvedAction(
                step: executionStep,
                metaJson: metaJson,
                recordingPath: recordingPath,
                isTriggeredAction: isTriggeredAction,
                options: options
            ) { [weak self] success in
                guard let self = self else { return }
                if !success {
                    self.clipboardMonitor.stopEarlyMonitoring(for: recordingPath)
                    onCompletion?(ChainExecutionResult(success: false, finalActionName: executionStep.name, finalActionType: executionStep.type, finalAction: executionStep.action, errorMessage: "Action execution failed for '\(executionStep.name)'"))
                    return
                }

                guard let nextStep else {
                    onCompletion?(ChainExecutionResult(success: true, finalActionName: executionStep.name, finalActionType: executionStep.type, finalAction: executionStep.action, errorMessage: nil))
                    return
                }

                let nextState = ChainRuntimeState(
                    currentStep: nextStep,
                    visited: nextVisited,
                    firstInsertActionName: nextFirstInsertActionName,
                    cachedInputFieldState: cachedInputState,
                    stepNumber: state.stepNumber + 1,
                    isFirstStep: false
                )
                self.executeActionChainStep(
                    state: nextState,
                    metaJson: metaJson,
                    recordingPath: recordingPath,
                    isTriggeredAction: isTriggeredAction,
                    onCompletion: onCompletion
                )
            }
        } catch {
            let message = error.localizedDescription
            logError("[ActionChain] \(message)")
            clipboardMonitor.stopEarlyMonitoring(for: recordingPath)
            onCompletion?(ChainExecutionResult(success: false, finalActionName: state.currentStep.name, finalActionType: state.currentStep.type, finalAction: state.currentStep.action, errorMessage: message))
        }
    }

    private enum InputConditionToken: String {
        case restoreClipboard
        case pressReturn
        case noEsc
        case nextAction
        case moveTo
        case action
        case actionDelay
        case simKeypress
    }

    private func resolveStepForExecution(
        step: ResolvedActionStep,
        cachedInputFieldState: Bool?
    ) -> (ResolvedActionStep, Bool?) {
        guard step.type == .insert, let rawInsert = step.action as? AppConfiguration.Insert else {
            return (step, cachedInputFieldState)
        }

        let (templateInsert, isLegacyAutoPasteTemplate) = applyLegacyInsertTemplateOverrides(rawInsert)
        let needsInputConditionEvaluation =
            isLegacyAutoPasteTemplate || !((templateInsert.inputCondition ?? "").isEmpty)

        var inputFieldState = cachedInputFieldState
        if needsInputConditionEvaluation && inputFieldState == nil {
            if requestAccessibilityPermission() {
                inputFieldState = isInInputField()
            } else {
                inputFieldState = false
            }
        }

        let resolvedInsert = applyInputCondition(
            to: templateInsert,
            isInInputField: inputFieldState ?? false
        )
        let resolvedStep = ResolvedActionStep(
            action: resolvedInsert,
            name: step.name,
            type: step.type
        )
        return (resolvedStep, inputFieldState)
    }

    private func applyLegacyInsertTemplateOverrides(_ insert: AppConfiguration.Insert) -> (AppConfiguration.Insert, Bool) {
        var resolved = insert

        if insert.action == ".autoPaste" {
            resolved.inputCondition = "!restoreClipboard|!noEsc"
            resolved.noEsc = true
            resolved.restoreClipboard = false
            return (resolved, true)
        }

        if insert.action == ".none" {
            resolved.action = ""
            resolved.inputCondition = ""
            resolved.noEsc = true
            resolved.restoreClipboard = false
        }

        return (resolved, false)
    }

    private func parseInputCondition(_ rawValue: String?) -> [InputConditionToken: Bool] {
        let normalized = rawValue ?? ""
        if normalized.isEmpty {
            return [:]
        }

        var tokens: [InputConditionToken: Bool] = [:]
        for rawToken in normalized.components(separatedBy: "|") {
            if rawToken.isEmpty {
                continue
            }

            let appliesOutsideInput = rawToken.hasPrefix("!")
            let tokenName = appliesOutsideInput ? String(rawToken.dropFirst()) : rawToken
            guard let token = InputConditionToken(rawValue: tokenName) else {
                continue
            }
            tokens[token] = appliesOutsideInput ? false : true
        }

        return tokens
    }

    private func shouldApplyToken(
        _ token: InputConditionToken,
        tokens: [InputConditionToken: Bool],
        isInInputField: Bool
    ) -> Bool {
        guard let appliesInInput = tokens[token] else {
            return true
        }
        return appliesInInput ? isInInputField : !isInInputField
    }

    private func applyInputCondition(
        to insert: AppConfiguration.Insert,
        isInInputField: Bool
    ) -> AppConfiguration.Insert {
        let tokens = parseInputCondition(insert.inputCondition)
        if tokens.isEmpty {
            return insert
        }

        var resolved = insert
        if !shouldApplyToken(.restoreClipboard, tokens: tokens, isInInputField: isInInputField) {
            resolved.restoreClipboard = nil
        }
        if !shouldApplyToken(.pressReturn, tokens: tokens, isInInputField: isInInputField) {
            resolved.pressReturn = nil
        }
        if !shouldApplyToken(.noEsc, tokens: tokens, isInInputField: isInInputField) {
            resolved.noEsc = nil
        }
        if !shouldApplyToken(.nextAction, tokens: tokens, isInInputField: isInInputField) {
            resolved.nextAction = nil
        }
        if !shouldApplyToken(.moveTo, tokens: tokens, isInInputField: isInInputField) {
            resolved.moveTo = nil
        }
        if !shouldApplyToken(.action, tokens: tokens, isInInputField: isInInputField) {
            resolved.action = ""
        }
        if !shouldApplyToken(.actionDelay, tokens: tokens, isInInputField: isInInputField) {
            resolved.actionDelay = nil
        }
        if !shouldApplyToken(.simKeypress, tokens: tokens, isInInputField: isInInputField) {
            resolved.simKeypress = nil
        }

        return resolved
    }

    private func executeResolvedAction(
        step: ResolvedActionStep,
        metaJson: [String: Any],
        recordingPath: String,
        isTriggeredAction: Bool,
        options: StepExecutionOptions,
        onCompletion: ((Bool) -> Void)? = nil
    ) {
        switch step.type {
        case .insert:
            guard let insert = step.action as? AppConfiguration.Insert else {
                onCompletion?(false)
                return
            }
            executeInsertAction(
                insert,
                metaJson: metaJson,
                recordingPath: recordingPath,
                isTriggeredAction: isTriggeredAction,
                options: options,
                onCompletion: onCompletion
            )
        case .url:
            guard let url = step.action as? AppConfiguration.Url else {
                onCompletion?(false)
                return
            }
            executeUrlAction(url, metaJson: metaJson, recordingPath: recordingPath, options: options, onCompletion: onCompletion)
        case .shortcut:
            guard let shortcut = step.action as? AppConfiguration.Shortcut else {
                onCompletion?(false)
                return
            }
            executeShortcutAction(shortcut, metaJson: metaJson, recordingPath: recordingPath, shortcutName: step.name, options: options, onCompletion: onCompletion)
        case .shell:
            guard let shell = step.action as? AppConfiguration.ScriptShell else {
                onCompletion?(false)
                return
            }
            executeShellScriptAction(shell, metaJson: metaJson, recordingPath: recordingPath, options: options, onCompletion: onCompletion)
        case .appleScript:
            guard let ascript = step.action as? AppConfiguration.ScriptAppleScript else {
                onCompletion?(false)
                return
            }
            executeAppleScriptAction(ascript, metaJson: metaJson, recordingPath: recordingPath, options: options, onCompletion: onCompletion)
        }
    }
    
    private func executeInsertAction(
        _ insert: AppConfiguration.Insert,
        metaJson: [String: Any],
        recordingPath: String,
        isTriggeredAction: Bool,
        options: StepExecutionOptions,
        onCompletion: ((Bool) -> Void)? = nil
    ) {
        // Enhance metaJson with session data from clipboard monitor
        let enhancedMetaJson = enhanceMetaJsonWithSessionData(metaJson: metaJson, recordingPath: recordingPath)
        
        let (processedAction, isAutoPasteResult) = socketCommunication.processInsertAction(insert.action, metaJson: enhancedMetaJson)
        let baseShouldEsc = !(insert.noEsc ?? configManager.config.defaults.noEsc)
        var shouldEsc = options.isFirstInChain ? baseShouldEsc : false
        let actionDelay = insert.actionDelay ?? configManager.config.defaults.actionDelay

        let isAutoPaste = isAutoPasteResult || insert.action == ".autoPaste"
        let isEmptyOrNoneInsert = processedAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // Respect noEsc=true strictly. Forced ESC only applies when ESC is otherwise allowed.
        let forceEscForAutoPasteWhenNotInInputField = !options.isLastInChain && baseShouldEsc && isAutoPaste
        let forceEscForEmptyInsert = !options.isLastInChain && baseShouldEsc && isEmptyOrNoneInsert
        if forceEscForAutoPasteWhenNotInInputField || forceEscForEmptyInsert {
            shouldEsc = true
        }

        // Only the last action controls clipboard restoration decision.
        let restoreClipboard = options.isLastInChain
            ? (insert.restoreClipboard ?? configManager.config.defaults.restoreClipboard)
            : false
        
        clipboardMonitor.executeInsertWithEnhancedClipboardSync(
            insertAction: { [weak self] in
                // Execute the insert action without ESC (already handled by clipboard monitor)
                return self?.socketCommunication.applyInsertWithoutEsc(
                    processedAction,
                    activeInsert: insert,
                    isAutoPaste: isAutoPaste
                ) ?? false
            },
            actionDelay: actionDelay,
            shouldEsc: shouldEsc,
            isAutoPaste: isAutoPaste,
            recordingPath: recordingPath,
            metaJson: enhancedMetaJson,
            restoreClipboard: restoreClipboard,
            shouldUseSuperwhisperSync: options.isFirstInChain,
            shouldStopMonitoringAfterAction: options.isLastInChain,
            shouldTriggerCleanupAfterAction: options.isLastInChain,
            restoreClipboardIndependentlyOfEsc: options.isLastInChain,
            forceEscForAutoPasteWhenNotInInputField: forceEscForAutoPasteWhenNotInInputField,
            forceEscForEmptyInsert: forceEscForEmptyInsert,
            onCompletion: onCompletion
        )
    }
    
    private func executeUrlAction(
        _ url: AppConfiguration.Url,
        metaJson: [String: Any],
        recordingPath: String,
        options: StepExecutionOptions,
        onCompletion: ((Bool) -> Void)? = nil
    ) {
        // Enhance metaJson with session data from clipboard monitor
        let enhancedMetaJson = enhanceMetaJsonWithSessionData(metaJson: metaJson, recordingPath: recordingPath)
        
        let baseShouldEsc = !(url.noEsc ?? configManager.config.defaults.noEsc)
        let shouldEsc = options.isFirstInChain ? baseShouldEsc : false
        let actionDelay = url.actionDelay ?? configManager.config.defaults.actionDelay
        
        // Only the last action controls clipboard restoration decision.
        let restoreClipboard = options.isLastInChain ? (url.restoreClipboard ?? configManager.config.defaults.restoreClipboard) : false
        
        clipboardMonitor.executeNonInsertActionWithClipboardRestore(
            action: { [weak self] in
                self?.processUrlAction(url, metaJson: enhancedMetaJson) ?? false
            },
            shouldEsc: shouldEsc,
            actionDelay: actionDelay,
            recordingPath: recordingPath,
            restoreClipboard: restoreClipboard,
            shouldStopMonitoringAfterAction: options.isLastInChain,
            shouldTriggerCleanupAfterAction: options.isLastInChain,
            restoreClipboardIndependentlyOfEsc: options.isLastInChain,
            onCompletion: onCompletion
        )
    }
    
    private func executeShortcutAction(
        _ shortcut: AppConfiguration.Shortcut,
        metaJson: [String: Any],
        recordingPath: String,
        shortcutName: String,
        options: StepExecutionOptions,
        onCompletion: ((Bool) -> Void)? = nil
    ) {
        // Enhance metaJson with session data from clipboard monitor
        let enhancedMetaJson = enhanceMetaJsonWithSessionData(metaJson: metaJson, recordingPath: recordingPath)
        
        let baseShouldEsc = !(shortcut.noEsc ?? configManager.config.defaults.noEsc)
        let shouldEsc = options.isFirstInChain ? baseShouldEsc : false
        let actionDelay = shortcut.actionDelay ?? configManager.config.defaults.actionDelay
        
        // Only the last action controls clipboard restoration decision.
        let restoreClipboard = options.isLastInChain ? (shortcut.restoreClipboard ?? configManager.config.defaults.restoreClipboard) : false
        
        clipboardMonitor.executeNonInsertActionWithClipboardRestore(
            action: { [weak self] in
                self?.processShortcutAction(shortcut, shortcutName: shortcutName, metaJson: enhancedMetaJson) ?? false
            },
            shouldEsc: shouldEsc,
            actionDelay: actionDelay,
            recordingPath: recordingPath,
            restoreClipboard: restoreClipboard,
            shouldStopMonitoringAfterAction: options.isLastInChain,
            shouldTriggerCleanupAfterAction: options.isLastInChain,
            restoreClipboardIndependentlyOfEsc: options.isLastInChain,
            onCompletion: onCompletion
        )
    }
    
    private func executeShellScriptAction(
        _ shell: AppConfiguration.ScriptShell,
        metaJson: [String: Any],
        recordingPath: String,
        options: StepExecutionOptions,
        onCompletion: ((Bool) -> Void)? = nil
    ) {
        // Enhance metaJson with session data from clipboard monitor
        let enhancedMetaJson = enhanceMetaJsonWithSessionData(metaJson: metaJson, recordingPath: recordingPath)
        
        let baseShouldEsc = !(shell.noEsc ?? configManager.config.defaults.noEsc)
        let shouldEsc = options.isFirstInChain ? baseShouldEsc : false
        let actionDelay = shell.actionDelay ?? configManager.config.defaults.actionDelay
        
        // Only the last action controls clipboard restoration decision.
        let restoreClipboard = options.isLastInChain ? (shell.restoreClipboard ?? configManager.config.defaults.restoreClipboard) : false
        
        clipboardMonitor.executeNonInsertActionWithClipboardRestore(
            action: { [weak self] in
                self?.processShellScriptAction(shell, metaJson: enhancedMetaJson) ?? false
            },
            shouldEsc: shouldEsc,
            actionDelay: actionDelay,
            recordingPath: recordingPath,
            restoreClipboard: restoreClipboard,
            shouldStopMonitoringAfterAction: options.isLastInChain,
            shouldTriggerCleanupAfterAction: options.isLastInChain,
            restoreClipboardIndependentlyOfEsc: options.isLastInChain,
            onCompletion: onCompletion
        )
    }
    
    private func executeAppleScriptAction(
        _ ascript: AppConfiguration.ScriptAppleScript,
        metaJson: [String: Any],
        recordingPath: String,
        options: StepExecutionOptions,
        onCompletion: ((Bool) -> Void)? = nil
    ) {
        // Enhance metaJson with session data from clipboard monitor
        let enhancedMetaJson = enhanceMetaJsonWithSessionData(metaJson: metaJson, recordingPath: recordingPath)
        
        let baseShouldEsc = !(ascript.noEsc ?? configManager.config.defaults.noEsc)
        let shouldEsc = options.isFirstInChain ? baseShouldEsc : false
        let actionDelay = ascript.actionDelay ?? configManager.config.defaults.actionDelay
        
        // Only the last action controls clipboard restoration decision.
        let restoreClipboard = options.isLastInChain ? (ascript.restoreClipboard ?? configManager.config.defaults.restoreClipboard) : false
        
        clipboardMonitor.executeNonInsertActionWithClipboardRestore(
            action: { [weak self] in
                self?.processAppleScriptAction(ascript, metaJson: enhancedMetaJson) ?? false
            },
            shouldEsc: shouldEsc,
            actionDelay: actionDelay,
            recordingPath: recordingPath,
            restoreClipboard: restoreClipboard,
            shouldStopMonitoringAfterAction: options.isLastInChain,
            shouldTriggerCleanupAfterAction: options.isLastInChain,
            restoreClipboardIndependentlyOfEsc: options.isLastInChain,
            onCompletion: onCompletion
        )
    }
    
    // MARK: - Helper Methods

    private enum ActionChainError: LocalizedError {
        case duplicateActionName(String)
        case missingAction(String)
        case cycleDetected(String)
        case multipleInsertActions(first: String, second: String)

        var errorDescription: String? {
            switch self {
            case .duplicateActionName(let name):
                return "Duplicate action name '\(name)' exists across multiple action types. Names must be unique."
            case .missingAction(let name):
                return "Chained nextAction '\(name)' was not found."
            case .cycleDetected(let name):
                return "Action chain cycle detected at '\(name)'. Chained actions cannot repeat."
            case .multipleInsertActions(let first, let second):
                return "Action chain contains multiple insert actions ('\(first)' and '\(second)'). Only one insert action is allowed per chain."
            }
        }
    }

    private func resolveActionChain(initialAction: Any, name: String, type: ActionType) throws -> [ResolvedActionStep] {
        var chain: [ResolvedActionStep] = []
        var visited: Set<String> = []
        var firstInsertActionName: String?

        var currentName = name
        var currentType = type
        var currentAction: Any = initialAction

        while true {
            if visited.contains(currentName) {
                throw ActionChainError.cycleDetected(currentName)
            }
            visited.insert(currentName)
            chain.append(ResolvedActionStep(action: currentAction, name: currentName, type: currentType))
            if currentType == .insert {
                if let firstInsertActionName = firstInsertActionName, firstInsertActionName != currentName {
                    throw ActionChainError.multipleInsertActions(first: firstInsertActionName, second: currentName)
                }
                firstInsertActionName = currentName
            }

            guard let nextActionName = getEffectiveNextActionName(
                for: currentAction,
                actionName: currentName,
                type: currentType,
                isFirstStep: chain.count == 1
            ), !nextActionName.isEmpty else {
                break
            }

            guard let next = try findUniqueActionByName(nextActionName) else {
                throw ActionChainError.missingAction(nextActionName)
            }
            currentName = next.name
            currentType = next.type
            currentAction = next.action
        }

        return chain
    }

    private func getEffectiveNextActionName(for action: Any, actionName: String, type: ActionType, isFirstStep: Bool) -> String? {
        let actionLevel: String?
        switch type {
        case .insert:
            actionLevel = (action as? AppConfiguration.Insert)?.nextAction
        case .url:
            actionLevel = (action as? AppConfiguration.Url)?.nextAction
        case .shortcut:
            actionLevel = (action as? AppConfiguration.Shortcut)?.nextAction
        case .shell:
            actionLevel = (action as? AppConfiguration.ScriptShell)?.nextAction
        case .appleScript:
            actionLevel = (action as? AppConfiguration.ScriptAppleScript)?.nextAction
        }
        let normalizedActionLevel = actionLevel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // defaults.nextAction overrides the first action's own nextAction.
        // For subsequent chained actions, only action-level nextAction is considered.
        if isFirstStep {
            let defaultsNext = configManager.config.defaults.nextAction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !defaultsNext.isEmpty {
                return defaultsNext
            }
            return normalizedActionLevel.isEmpty ? nil : normalizedActionLevel
        }

        // Never re-apply defaults.nextAction after first action.
        if normalizedActionLevel == actionName {
            return normalizedActionLevel
        }
        return normalizedActionLevel.isEmpty ? nil : normalizedActionLevel
    }

    private func findUniqueActionByName(_ name: String) throws -> (name: String, type: ActionType, action: Any)? {
        let config = configManager.config
        var matches: [(name: String, type: ActionType, action: Any)] = []
        if let insert = config.inserts[name] { matches.append((name: name, type: .insert, action: insert)) }
        if let url = config.urls[name] { matches.append((name: name, type: .url, action: url)) }
        if let shortcut = config.shortcuts[name] { matches.append((name: name, type: .shortcut, action: shortcut)) }
        if let shell = config.scriptsShell[name] { matches.append((name: name, type: .shell, action: shell)) }
        if let script = config.scriptsAS[name] { matches.append((name: name, type: .appleScript, action: script)) }
        if matches.count > 1 {
            throw ActionChainError.duplicateActionName(name)
        }
        return matches.first
    }
    
    /// Enhances metaJson with session data from clipboard monitor (selectedText, clipboardContext)
    private func enhanceMetaJsonWithSessionData(metaJson: [String: Any], recordingPath: String) -> [String: Any] {
        var enhanced = metaJson
        
        // Get selected text that was captured when recording session started
        let sessionSelectedText = clipboardMonitor.getSessionSelectedText(for: recordingPath)
        if !sessionSelectedText.isEmpty {
            enhanced["selectedText"] = sessionSelectedText
        }
        
        // Get clipboard content for the clipboardContext placeholder with stacking support
        let swResult = (metaJson["llmResult"] as? String) ?? (metaJson["result"] as? String) ?? ""
        let enableStacking = configManager.config.defaults.clipboardStacking
        let sessionClipboardContent = clipboardMonitor.getSessionClipboardContentWithStacking(for: recordingPath, swResult: swResult, enableStacking: enableStacking)
        if !sessionClipboardContent.isEmpty {
            enhanced["clipboardContext"] = sessionClipboardContent
        }
        
        return enhanced
    }
    
    // MARK: - Action Processing Methods
    
    private func processUrlAction(_ urlAction: AppConfiguration.Url, metaJson: [String: Any]) -> Bool {
        // Process the URL action with both XML and dynamic placeholders
        // Placeholders are now URL-encoded individually during processing
        let processedAction = processAllPlaceholders(action: urlAction.action, metaJson: metaJson, actionType: .url)
        
        // Try to create URL directly from processed action
        guard let url = URL(string: processedAction) else {
            logError("Invalid URL after processing: \(redactForLogs(processedAction))")
            return false
        }
        
        return openResolvedUrl(url, with: urlAction)
    }

    private func openResolvedUrl(_ url: URL, with urlAction: AppConfiguration.Url) -> Bool {
        // Check if URL should open in background
        let shouldOpenInBackground = urlAction.openBackground ?? false

        // If openWith is specified, use that app to open the URL
        if let openWith = urlAction.openWith, !openWith.isEmpty {
            let expandedOpenWith = (openWith as NSString).expandingTildeInPath
            let task = Process()
            task.launchPath = "/usr/bin/open"
            // Add -g flag only if openBackground is true
            if shouldOpenInBackground {
                task.arguments = ["-g", "-a", expandedOpenWith, url.absoluteString]
            } else {
                task.arguments = ["-a", expandedOpenWith, url.absoluteString]
            }
            do {
                try task.run()
                return true
            } catch {
                logError("Failed to open URL with specified app: \(error)")
                // Fallback to opening with default handler
                return openUrl(url, inBackground: shouldOpenInBackground)
            }
        } else {
            // Open with default handler
            return openUrl(url, inBackground: shouldOpenInBackground)
        }
    }

    // Helper method to open URLs with background option
    private func openUrl(_ url: URL, inBackground: Bool) -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        // Use -g flag only if opening in background
        if inBackground {
            task.arguments = ["-g", url.absoluteString]
        } else {
            task.arguments = [url.absoluteString]
        }
        do {
            try task.run()
            logDebug("URL opened \(inBackground ? "in background" : "normally"): \(redactForLogs(url.absoluteString))")
            return true
        } catch {
            logError("Failed to open URL \(inBackground ? "in background" : "normally"): \(error)")
            // Ultimate fallback to standard opening
            return NSWorkspace.shared.open(url)
        }
    }
    
    private func processShortcutAction(_ shortcut: AppConfiguration.Shortcut, shortcutName: String, metaJson: [String: Any]) -> Bool {
        let processedAction = processAllPlaceholders(action: shortcut.action, metaJson: metaJson, actionType: .shortcut)
        
        logDebug("[ShortcutAction] Processed action before sending to shortcuts: \(redactForLogs(processedAction))")
        
        // Check if action is .none or empty - if so, run shortcut without input
        if processedAction == ".none" || processedAction.isEmpty {
            logDebug("[ShortcutAction] Action is '.none' or empty - running shortcut without input")
            
            let task = Process()
            task.launchPath = "/usr/bin/shortcuts"
            task.arguments = ["run", shortcutName]
            task.environment = getUTF8Environment()
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice

            do {
                try task.run()
                logDebug("[ShortcutAction] Shortcut launched without input")
                return true
            } catch {
                logError("Failed to execute shortcut action without input: \(error)")
                return false
            }
        } else {
            // Use temporary file approach to ensure proper UTF-8 encoding
            let tempDir = NSTemporaryDirectory()
            let tempFile = tempDir + "macrowhisper_shortcut_input_\(UUID().uuidString).txt"
            
            do {
                // Write the processed action to a temporary file with explicit UTF-8 encoding
                try processedAction.write(toFile: tempFile, atomically: true, encoding: .utf8)
                logDebug("[ShortcutAction] Wrote UTF-8 content to temporary file: \(tempFile)")
                
                let task = Process()
                task.launchPath = "/usr/bin/shortcuts"
                task.arguments = ["run", shortcutName, "-i", tempFile]
                task.environment = getUTF8Environment()
                task.standardOutput = FileHandle.nullDevice
                task.standardError = FileHandle.nullDevice

                try task.run()
                logDebug("[ShortcutAction] Shortcut launched with temporary file input")
                
                // Clean up the temporary file after a short delay to ensure shortcuts has read it
                DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                    do {
                        try FileManager.default.removeItem(atPath: tempFile)
                        logDebug("[ShortcutAction] Cleaned up temporary file: \(tempFile)")
                    } catch {
                        logWarning("[ShortcutAction] Failed to clean up temporary file \(tempFile): \(error)")
                    }
                }
                return true
            } catch {
                logError("Failed to execute shortcut action: \(error)")
                // Clean up temp file on error
                try? FileManager.default.removeItem(atPath: tempFile)
                return false
            }
        }
        // ESC simulation and action delay are now handled by ClipboardMonitor
    }
    
    private func processShellScriptAction(_ shell: AppConfiguration.ScriptShell, metaJson: [String: Any]) -> Bool {
        let processedAction = processAllPlaceholders(action: shell.action, metaJson: metaJson, actionType: .shell)
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", processedAction]
        task.environment = getUTF8Environment()
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            logDebug("Shell script launched asynchronously")
            return true
        } catch {
            logError("Failed to execute shell script: \(error)")
            return false
        }
        // ESC simulation and action delay are now handled by ClipboardMonitor
    }
    
    private func processAppleScriptAction(_ ascript: AppConfiguration.ScriptAppleScript, metaJson: [String: Any]) -> Bool {
        let processedAction = processAllPlaceholders(action: ascript.action, metaJson: metaJson, actionType: .appleScript)
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", processedAction]
        task.environment = getUTF8Environment()
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            logDebug("AppleScript launched asynchronously")
            return true
        } catch {
            logError("Failed to execute AppleScript action: \(error)")
            return false
        }
        // ESC simulation and action delay are now handled by ClipboardMonitor
    }
    
    // MARK: - Helper Methods
    
    private func getUTF8Environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        let utf8Locale: String
        if let existingLang = env["LANG"], !existingLang.isEmpty {
            if existingLang.contains("UTF-8") || existingLang.contains("utf8") {
                // Already has UTF-8, use as-is
                utf8Locale = existingLang
                logDebug("[UTF8Env] Using existing UTF-8 locale: \(utf8Locale)")
            } else if existingLang == "C" || existingLang == "POSIX" {
                // Invalid locale for launchd services - use en_US.UTF-8
                utf8Locale = "en_US.UTF-8"
                logDebug("[UTF8Env] Detected invalid locale '\(existingLang)', using fallback: \(utf8Locale)")
            } else {
                // Has a base locale, append UTF-8
                let baseLocale = existingLang.components(separatedBy: ".").first ?? "en_US"
                utf8Locale = "\(baseLocale).UTF-8"
                logDebug("[UTF8Env] Appending UTF-8 to base locale: \(utf8Locale)")
            }
        } else {
            // No LANG set, use system locale
            let localeIdentifier = Locale.current.identifier
            let normalizedIdentifier = localeIdentifier.replacingOccurrences(of: "-", with: "_")
            utf8Locale = "\(normalizedIdentifier).UTF-8"
            logDebug("[UTF8Env] No LANG set, using system locale: \(utf8Locale)")
        }

        env["LANG"] = utf8Locale
        env["LC_ALL"] = utf8Locale

        return env
    }
    
    private func handleMoveToSetting(folderPath: String, activeInsert: AppConfiguration.Insert?) {
        // Determine the moveTo value with proper precedence
        var moveTo: String?
        if let activeInsert = activeInsert, let insertMoveTo = activeInsert.moveTo, !insertMoveTo.isEmpty {
            // Insert has an explicit moveTo value (including ".none" and ".delete")
            moveTo = insertMoveTo
        } else {
            // Insert moveTo is nil or empty, fall back to default
            moveTo = configManager.config.defaults.moveTo
        }
        
        // Handle the moveTo action
        if let path = moveTo, !path.isEmpty {
            if path == ".delete" {
                logInfo("Deleting processed recording folder: \(folderPath)")
                try? FileManager.default.removeItem(atPath: folderPath)
            } else if path == ".none" {
                logInfo("Keeping folder in place as requested by .none setting")
                // Explicitly do nothing
            } else {
                let expandedPath = (path as NSString).expandingTildeInPath
                let destinationUrl = URL(fileURLWithPath: expandedPath).appendingPathComponent((folderPath as NSString).lastPathComponent)
                logInfo("Moving processed recording folder to: \(destinationUrl.path)")
                try? FileManager.default.moveItem(atPath: folderPath, toPath: destinationUrl.path)
            }
        }
    }
    
    private func handleMoveToSettingForAction(folderPath: String, action: Any) {
        // Determine the moveTo value with proper precedence for different action types
        var moveTo: String?
        
        if let url = action as? AppConfiguration.Url {
            if let actionMoveTo = url.moveTo, !actionMoveTo.isEmpty {
                moveTo = actionMoveTo
            } else {
                moveTo = configManager.config.defaults.moveTo
            }
        } else if let shortcut = action as? AppConfiguration.Shortcut {
            if let actionMoveTo = shortcut.moveTo, !actionMoveTo.isEmpty {
                moveTo = actionMoveTo
            } else {
                moveTo = configManager.config.defaults.moveTo
            }
        } else if let shell = action as? AppConfiguration.ScriptShell {
            if let actionMoveTo = shell.moveTo, !actionMoveTo.isEmpty {
                moveTo = actionMoveTo
            } else {
                moveTo = configManager.config.defaults.moveTo
            }
        } else if let ascript = action as? AppConfiguration.ScriptAppleScript {
            if let actionMoveTo = ascript.moveTo, !actionMoveTo.isEmpty {
                moveTo = actionMoveTo
            } else {
                moveTo = configManager.config.defaults.moveTo
            }
        } else {
            // Fallback to default
            moveTo = configManager.config.defaults.moveTo
        }
        
        // Handle the moveTo action
        if let path = moveTo, !path.isEmpty {
            if path == ".delete" {
                logInfo("Deleting processed recording folder: \(folderPath)")
                try? FileManager.default.removeItem(atPath: folderPath)
            } else if path == ".none" {
                logInfo("Keeping folder in place as requested by .none setting")
                // Explicitly do nothing
            } else {
                let expandedPath = (path as NSString).expandingTildeInPath
                let destinationUrl = URL(fileURLWithPath: expandedPath).appendingPathComponent((folderPath as NSString).lastPathComponent)
                logInfo("Moving processed recording folder to: \(destinationUrl.path)")
                try? FileManager.default.moveItem(atPath: folderPath, toPath: destinationUrl.path)
            }
        }
    }
    
    private func simulateEscKeyPress(activeInsert: AppConfiguration.Insert?) {
        // Use insert-specific noEsc if set, otherwise fall back to global default
        let shouldSkipEsc = activeInsert?.noEsc ?? configManager.config.defaults.noEsc
        if !shouldSkipEsc {
            DispatchQueue.main.async {
                simulateKeyDown(key: 53) // ESC key
            }
        }
    }
} 
