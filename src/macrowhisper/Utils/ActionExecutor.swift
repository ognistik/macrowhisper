import Foundation
import Cocoa

/// Handles execution of different action types
class ActionExecutor {
    private let logger: Logger
    private let socketCommunication: SocketCommunication
    private let configManager: ConfigurationManager
    private let clipboardMonitor: ClipboardMonitor
    private let chainContextQueue = DispatchQueue(label: "com.macrowhisper.actionexecutor.chaincontext")
    private var chainContextByRecordingPath: [String: ChainContextSnapshot] = [:]
    private var chainContextRefCountByRecordingPath: [String: Int] = [:]
    
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

    private struct ChainContextSnapshot {
        var frontAppName: String
        var frontAppBundleId: String
        var frontAppPid: Int32?
        var didResolveAppContext: Bool
        var appContext: String
        var didResolveAppVocabulary: Bool
        var appVocabulary: String
    }

    private struct ChainRuntimeState {
        let currentStep: ResolvedActionStep
        let visited: Set<String>
        let firstInsertActionName: String?
        let cachedInputFieldState: Bool?
        let failedSteps: [String]
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
        initializeChainContextSnapshot(recordingPath: recordingPath, metaJson: metaJson)
        let initialStep = ResolvedActionStep(action: initialAction, name: name, type: type)
        let initialState = ChainRuntimeState(
            currentStep: initialStep,
            visited: [],
            firstInsertActionName: nil,
            cachedInputFieldState: nil,
            failedSteps: [],
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
                var nextFailedSteps = state.failedSteps
                if !success {
                    nextFailedSteps.append(executionStep.name)
                    logError("[ActionChain] Action execution failed for '\(executionStep.name)' (continuing chain)")
                }

                guard let nextStep else {
                    let didFullySucceed = nextFailedSteps.isEmpty
                    let errorMessage = didFullySucceed
                        ? nil
                        : "Action chain completed with failures in: \(nextFailedSteps.joined(separator: ", "))"
                    self.clearChainContextSnapshot(recordingPath: recordingPath)
                    onCompletion?(ChainExecutionResult(success: didFullySucceed, finalActionName: executionStep.name, finalActionType: executionStep.type, finalAction: executionStep.action, errorMessage: errorMessage))
                    return
                }

                let nextState = ChainRuntimeState(
                    currentStep: nextStep,
                    visited: nextVisited,
                    firstInsertActionName: nextFirstInsertActionName,
                    cachedInputFieldState: cachedInputState,
                    failedSteps: nextFailedSteps,
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
            clearChainContextSnapshot(recordingPath: recordingPath)
            clipboardMonitor.stopEarlyMonitoring(for: recordingPath)
            onCompletion?(ChainExecutionResult(success: false, finalActionName: state.currentStep.name, finalActionType: state.currentStep.type, finalAction: state.currentStep.action, errorMessage: message))
        }
    }

    private typealias ParsedInputCondition = [String: Bool]

    private func resolveStepForExecution(
        step: ResolvedActionStep,
        cachedInputFieldState: Bool?
    ) -> (ResolvedActionStep, Bool?) {
        var resolvedAction = step.action
        var needsInputConditionEvaluation = false

        switch step.type {
        case .insert:
            guard let rawInsert = step.action as? AppConfiguration.Insert else {
                return (step, cachedInputFieldState)
            }
            let (templateInsert, isLegacyAutoPasteTemplate) = applyLegacyInsertTemplateOverrides(rawInsert)
            needsInputConditionEvaluation = isLegacyAutoPasteTemplate || !((templateInsert.inputCondition ?? "").isEmpty)
            resolvedAction = templateInsert
        case .url:
            guard let rawUrl = step.action as? AppConfiguration.Url else {
                return (step, cachedInputFieldState)
            }
            let (templateUrl, isLegacyNoopTemplate) = applyLegacyNoopTemplateOverrides(rawUrl)
            needsInputConditionEvaluation = isLegacyNoopTemplate || !((templateUrl.inputCondition ?? "").isEmpty)
            resolvedAction = templateUrl
        case .shell:
            guard let rawShell = step.action as? AppConfiguration.ScriptShell else {
                return (step, cachedInputFieldState)
            }
            let (templateShell, isLegacyNoopTemplate) = applyLegacyNoopTemplateOverrides(rawShell)
            needsInputConditionEvaluation = isLegacyNoopTemplate || !((templateShell.inputCondition ?? "").isEmpty)
            resolvedAction = templateShell
        case .appleScript:
            guard let rawAppleScript = step.action as? AppConfiguration.ScriptAppleScript else {
                return (step, cachedInputFieldState)
            }
            let (templateAppleScript, isLegacyNoopTemplate) = applyLegacyNoopTemplateOverrides(rawAppleScript)
            needsInputConditionEvaluation = isLegacyNoopTemplate || !((templateAppleScript.inputCondition ?? "").isEmpty)
            resolvedAction = templateAppleScript
        case .shortcut:
            guard let rawShortcut = step.action as? AppConfiguration.Shortcut else {
                return (step, cachedInputFieldState)
            }
            let (templateShortcut, isLegacyNoopTemplate) = applyLegacyNoopTemplateOverrides(rawShortcut)
            needsInputConditionEvaluation = isLegacyNoopTemplate || !((templateShortcut.inputCondition ?? "").isEmpty)
            resolvedAction = templateShortcut
        }

        var inputFieldState = cachedInputFieldState
        if needsInputConditionEvaluation && inputFieldState == nil {
            if requestAccessibilityPermission() {
                inputFieldState = isInInputField()
            } else {
                inputFieldState = false
            }
        }

        let inInputField = inputFieldState ?? false
        let conditionedAction: Any
        switch step.type {
        case .insert:
            guard let insert = resolvedAction as? AppConfiguration.Insert else {
                return (step, inputFieldState)
            }
            conditionedAction = applyInputCondition(to: insert, isInInputField: inInputField)
        case .url:
            guard let url = resolvedAction as? AppConfiguration.Url else {
                return (step, inputFieldState)
            }
            conditionedAction = applyInputCondition(to: url, isInInputField: inInputField)
        case .shell:
            guard let shell = resolvedAction as? AppConfiguration.ScriptShell else {
                return (step, inputFieldState)
            }
            conditionedAction = applyInputCondition(to: shell, isInInputField: inInputField)
        case .appleScript:
            guard let appleScript = resolvedAction as? AppConfiguration.ScriptAppleScript else {
                return (step, inputFieldState)
            }
            conditionedAction = applyInputCondition(to: appleScript, isInInputField: inInputField)
        case .shortcut:
            guard let shortcut = resolvedAction as? AppConfiguration.Shortcut else {
                return (step, inputFieldState)
            }
            conditionedAction = applyInputCondition(to: shortcut, isInInputField: inInputField)
        }

        return (
            ResolvedActionStep(action: conditionedAction, name: step.name, type: step.type),
            inputFieldState
        )
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

    private func applyLegacyNoopTemplateOverrides(_ url: AppConfiguration.Url) -> (AppConfiguration.Url, Bool) {
        var resolved = url

        if url.action == ".none" {
            resolved.action = ""
            resolved.inputCondition = ""
            resolved.noEsc = true
            resolved.restoreClipboard = false
            return (resolved, true)
        }

        return (resolved, false)
    }

    private func applyLegacyNoopTemplateOverrides(_ shell: AppConfiguration.ScriptShell) -> (AppConfiguration.ScriptShell, Bool) {
        var resolved = shell

        if shell.action == ".none" {
            resolved.action = ""
            resolved.inputCondition = ""
            resolved.noEsc = true
            resolved.restoreClipboard = false
            return (resolved, true)
        }

        return (resolved, false)
    }

    private func applyLegacyNoopTemplateOverrides(_ ascript: AppConfiguration.ScriptAppleScript) -> (AppConfiguration.ScriptAppleScript, Bool) {
        var resolved = ascript

        if ascript.action == ".none" {
            resolved.action = ""
            resolved.inputCondition = ""
            resolved.noEsc = true
            resolved.restoreClipboard = false
            return (resolved, true)
        }

        return (resolved, false)
    }

    private func applyLegacyNoopTemplateOverrides(_ shortcut: AppConfiguration.Shortcut) -> (AppConfiguration.Shortcut, Bool) {
        var resolved = shortcut

        if shortcut.action == ".none" {
            resolved.action = ""
            resolved.inputCondition = ""
            resolved.noEsc = true
            resolved.restoreClipboard = false
            return (resolved, true)
        }

        return (resolved, false)
    }

    private func parseInputCondition(_ rawValue: String?) -> ParsedInputCondition {
        let normalized = rawValue ?? ""
        if normalized.isEmpty {
            return [:]
        }

        var tokens: ParsedInputCondition = [:]
        for rawToken in normalized.components(separatedBy: "|") {
            if rawToken.isEmpty {
                continue
            }

            let appliesOutsideInput = rawToken.hasPrefix("!")
            let tokenName = appliesOutsideInput ? String(rawToken.dropFirst()) : rawToken
            if tokenName.isEmpty {
                continue
            }
            tokens[tokenName] = appliesOutsideInput ? false : true
        }

        return tokens
    }

    private func shouldApplyToken(
        _ token: String,
        tokens: ParsedInputCondition,
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
        if !shouldApplyToken("restoreClipboard", tokens: tokens, isInInputField: isInInputField) {
            resolved.restoreClipboard = nil
        }
        if !shouldApplyToken("restoreClipboardDelay", tokens: tokens, isInInputField: isInInputField) {
            resolved.restoreClipboardDelay = nil
        }
        if !shouldApplyToken("pressReturn", tokens: tokens, isInInputField: isInInputField) {
            resolved.pressReturn = nil
        }
        if !shouldApplyToken("noEsc", tokens: tokens, isInInputField: isInInputField) {
            resolved.noEsc = nil
        }
        if !shouldApplyToken("nextAction", tokens: tokens, isInInputField: isInInputField) {
            resolved.nextAction = nil
        }
        if !shouldApplyToken("moveTo", tokens: tokens, isInInputField: isInInputField) {
            resolved.moveTo = nil
        }
        if !shouldApplyToken("action", tokens: tokens, isInInputField: isInInputField) {
            resolved.action = ""
        }
        if !shouldApplyToken("actionDelay", tokens: tokens, isInInputField: isInInputField) {
            resolved.actionDelay = nil
        }

        return resolved
    }

    private func applyInputCondition(
        to url: AppConfiguration.Url,
        isInInputField: Bool
    ) -> AppConfiguration.Url {
        let tokens = parseInputCondition(url.inputCondition)
        if tokens.isEmpty {
            return url
        }

        var resolved = url
        if !shouldApplyToken("restoreClipboard", tokens: tokens, isInInputField: isInInputField) {
            resolved.restoreClipboard = nil
        }
        if !shouldApplyToken("restoreClipboardDelay", tokens: tokens, isInInputField: isInInputField) {
            resolved.restoreClipboardDelay = nil
        }
        if !shouldApplyToken("noEsc", tokens: tokens, isInInputField: isInInputField) {
            resolved.noEsc = nil
        }
        if !shouldApplyToken("nextAction", tokens: tokens, isInInputField: isInInputField) {
            resolved.nextAction = nil
        }
        if !shouldApplyToken("moveTo", tokens: tokens, isInInputField: isInInputField) {
            resolved.moveTo = nil
        }
        if !shouldApplyToken("action", tokens: tokens, isInInputField: isInInputField) {
            resolved.action = ""
        }
        if !shouldApplyToken("actionDelay", tokens: tokens, isInInputField: isInInputField) {
            resolved.actionDelay = nil
        }

        return resolved
    }

    private func applyInputCondition(
        to shell: AppConfiguration.ScriptShell,
        isInInputField: Bool
    ) -> AppConfiguration.ScriptShell {
        let tokens = parseInputCondition(shell.inputCondition)
        if tokens.isEmpty {
            return shell
        }

        var resolved = shell
        if !shouldApplyToken("restoreClipboard", tokens: tokens, isInInputField: isInInputField) {
            resolved.restoreClipboard = nil
        }
        if !shouldApplyToken("restoreClipboardDelay", tokens: tokens, isInInputField: isInInputField) {
            resolved.restoreClipboardDelay = nil
        }
        if !shouldApplyToken("noEsc", tokens: tokens, isInInputField: isInInputField) {
            resolved.noEsc = nil
        }
        if !shouldApplyToken("nextAction", tokens: tokens, isInInputField: isInInputField) {
            resolved.nextAction = nil
        }
        if !shouldApplyToken("moveTo", tokens: tokens, isInInputField: isInInputField) {
            resolved.moveTo = nil
        }
        if !shouldApplyToken("action", tokens: tokens, isInInputField: isInInputField) {
            resolved.action = ""
        }
        if !shouldApplyToken("actionDelay", tokens: tokens, isInInputField: isInInputField) {
            resolved.actionDelay = nil
        }
        if !shouldApplyToken("scriptAsync", tokens: tokens, isInInputField: isInInputField) {
            resolved.scriptAsync = nil
        }
        if !shouldApplyToken("scriptWaitTimeout", tokens: tokens, isInInputField: isInInputField) {
            resolved.scriptWaitTimeout = nil
        }

        return resolved
    }

    private func applyInputCondition(
        to ascript: AppConfiguration.ScriptAppleScript,
        isInInputField: Bool
    ) -> AppConfiguration.ScriptAppleScript {
        let tokens = parseInputCondition(ascript.inputCondition)
        if tokens.isEmpty {
            return ascript
        }

        var resolved = ascript
        if !shouldApplyToken("restoreClipboard", tokens: tokens, isInInputField: isInInputField) {
            resolved.restoreClipboard = nil
        }
        if !shouldApplyToken("restoreClipboardDelay", tokens: tokens, isInInputField: isInInputField) {
            resolved.restoreClipboardDelay = nil
        }
        if !shouldApplyToken("noEsc", tokens: tokens, isInInputField: isInInputField) {
            resolved.noEsc = nil
        }
        if !shouldApplyToken("nextAction", tokens: tokens, isInInputField: isInInputField) {
            resolved.nextAction = nil
        }
        if !shouldApplyToken("moveTo", tokens: tokens, isInInputField: isInInputField) {
            resolved.moveTo = nil
        }
        if !shouldApplyToken("action", tokens: tokens, isInInputField: isInInputField) {
            resolved.action = ""
        }
        if !shouldApplyToken("actionDelay", tokens: tokens, isInInputField: isInInputField) {
            resolved.actionDelay = nil
        }
        if !shouldApplyToken("scriptAsync", tokens: tokens, isInInputField: isInInputField) {
            resolved.scriptAsync = nil
        }
        if !shouldApplyToken("scriptWaitTimeout", tokens: tokens, isInInputField: isInInputField) {
            resolved.scriptWaitTimeout = nil
        }

        return resolved
    }

    private func applyInputCondition(
        to shortcut: AppConfiguration.Shortcut,
        isInInputField: Bool
    ) -> AppConfiguration.Shortcut {
        let tokens = parseInputCondition(shortcut.inputCondition)
        if tokens.isEmpty {
            return shortcut
        }

        var resolved = shortcut
        if !shouldApplyToken("restoreClipboard", tokens: tokens, isInInputField: isInInputField) {
            resolved.restoreClipboard = nil
        }
        if !shouldApplyToken("restoreClipboardDelay", tokens: tokens, isInInputField: isInInputField) {
            resolved.restoreClipboardDelay = nil
        }
        if !shouldApplyToken("noEsc", tokens: tokens, isInInputField: isInInputField) {
            resolved.noEsc = nil
        }
        if !shouldApplyToken("nextAction", tokens: tokens, isInInputField: isInInputField) {
            resolved.nextAction = nil
        }
        if !shouldApplyToken("moveTo", tokens: tokens, isInInputField: isInInputField) {
            resolved.moveTo = nil
        }
        if !shouldApplyToken("action", tokens: tokens, isInInputField: isInInputField) {
            resolved.action = ""
        }
        if !shouldApplyToken("actionDelay", tokens: tokens, isInInputField: isInInputField) {
            resolved.actionDelay = nil
        }
        if !shouldApplyToken("scriptAsync", tokens: tokens, isInInputField: isInInputField) {
            resolved.scriptAsync = nil
        }
        if !shouldApplyToken("scriptWaitTimeout", tokens: tokens, isInInputField: isInInputField) {
            resolved.scriptWaitTimeout = nil
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
        let enhancedMetaJson = enhanceMetaJsonWithSessionData(metaJson: metaJson, recordingPath: recordingPath, actionTemplate: insert.action)
        
        let processedInsert = socketCommunication.processInsertAction(
            insert.action,
            metaJson: enhancedMetaJson,
            activeInsert: insert
        )
        let baseShouldEsc = !(insert.noEsc ?? configManager.config.defaults.noEsc)
        var shouldEsc = options.isFirstInChain ? baseShouldEsc : false
        let actionDelay = insert.actionDelay ?? configManager.config.defaults.actionDelay

        let isAutoPaste = processedInsert.isAutoPaste || insert.action == ".autoPaste"
        let isEmptyOrNoneInsert = processedInsert.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

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
        let restoreDelay = options.isLastInChain
            ? (insert.restoreClipboardDelay ?? configManager.config.defaults.restoreClipboardDelay ?? 0.3)
            : (configManager.config.defaults.restoreClipboardDelay ?? 0.3)
        
        clipboardMonitor.executeInsertWithEnhancedClipboardSync(
            insertAction: { [weak self] in
                // Execute the insert action without ESC (already handled by clipboard monitor)
                return self?.socketCommunication.applyInsertWithoutEsc(
                    processedInsert.text,
                    activeInsert: insert,
                    isAutoPaste: isAutoPaste,
                    hadSmartCasingBlockingTransform: processedInsert.hadSmartCasingBlockingTransform
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
            restoreClipboardDelay: restoreDelay,
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
        let enhancedMetaJson = enhanceMetaJsonWithSessionData(metaJson: metaJson, recordingPath: recordingPath, actionTemplate: url.action)
        
        let baseShouldEsc = !(url.noEsc ?? configManager.config.defaults.noEsc)
        let shouldEsc = options.isFirstInChain ? baseShouldEsc : false
        let actionDelay = url.actionDelay ?? configManager.config.defaults.actionDelay
        
        // Only the last action controls clipboard restoration decision.
        let restoreClipboard = options.isLastInChain ? (url.restoreClipboard ?? configManager.config.defaults.restoreClipboard) : false
        let restoreDelay = options.isLastInChain
            ? (url.restoreClipboardDelay ?? configManager.config.defaults.restoreClipboardDelay ?? 0.3)
            : (configManager.config.defaults.restoreClipboardDelay ?? 0.3)
        
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
            restoreClipboardDelay: restoreDelay,
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
        let enhancedMetaJson = enhanceMetaJsonWithSessionData(metaJson: metaJson, recordingPath: recordingPath, actionTemplate: shortcut.action)
        
        let baseShouldEsc = !(shortcut.noEsc ?? configManager.config.defaults.noEsc)
        let shouldEsc = options.isFirstInChain ? baseShouldEsc : false
        let actionDelay = shortcut.actionDelay ?? configManager.config.defaults.actionDelay
        let effectiveScriptAsync = shortcut.scriptAsync ?? configManager.config.defaults.scriptAsync ?? true
        let effectiveScriptWaitTimeout = shortcut.scriptWaitTimeout ?? configManager.config.defaults.scriptWaitTimeout ?? 3.0
        
        // Only the last action controls clipboard restoration decision.
        let restoreClipboard = options.isLastInChain ? (shortcut.restoreClipboard ?? configManager.config.defaults.restoreClipboard) : false
        let restoreDelay = options.isLastInChain
            ? (shortcut.restoreClipboardDelay ?? configManager.config.defaults.restoreClipboardDelay ?? 0.3)
            : (configManager.config.defaults.restoreClipboardDelay ?? 0.3)
        
        clipboardMonitor.executeNonInsertActionWithClipboardRestore(
            action: { [weak self] in
                self?.processShortcutAction(
                    shortcut,
                    shortcutName: shortcutName,
                    metaJson: enhancedMetaJson,
                    recordingPath: recordingPath,
                    scriptAsync: effectiveScriptAsync,
                    scriptWaitTimeout: effectiveScriptWaitTimeout
                ) ?? false
            },
            shouldEsc: shouldEsc,
            actionDelay: actionDelay,
            recordingPath: recordingPath,
            restoreClipboard: restoreClipboard,
            shouldStopMonitoringAfterAction: options.isLastInChain,
            shouldTriggerCleanupAfterAction: options.isLastInChain,
            restoreClipboardIndependentlyOfEsc: options.isLastInChain,
            restoreClipboardDelay: restoreDelay,
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
        let enhancedMetaJson = enhanceMetaJsonWithSessionData(metaJson: metaJson, recordingPath: recordingPath, actionTemplate: shell.action)
        
        let baseShouldEsc = !(shell.noEsc ?? configManager.config.defaults.noEsc)
        let shouldEsc = options.isFirstInChain ? baseShouldEsc : false
        let actionDelay = shell.actionDelay ?? configManager.config.defaults.actionDelay
        let effectiveScriptAsync = shell.scriptAsync ?? configManager.config.defaults.scriptAsync ?? true
        let effectiveScriptWaitTimeout = shell.scriptWaitTimeout ?? configManager.config.defaults.scriptWaitTimeout ?? 3.0
        
        // Only the last action controls clipboard restoration decision.
        let restoreClipboard = options.isLastInChain ? (shell.restoreClipboard ?? configManager.config.defaults.restoreClipboard) : false
        let restoreDelay = options.isLastInChain
            ? (shell.restoreClipboardDelay ?? configManager.config.defaults.restoreClipboardDelay ?? 0.3)
            : (configManager.config.defaults.restoreClipboardDelay ?? 0.3)
        
        clipboardMonitor.executeNonInsertActionWithClipboardRestore(
            action: { [weak self] in
                self?.processShellScriptAction(
                    shell,
                    metaJson: enhancedMetaJson,
                    recordingPath: recordingPath,
                    scriptAsync: effectiveScriptAsync,
                    scriptWaitTimeout: effectiveScriptWaitTimeout
                ) ?? false
            },
            shouldEsc: shouldEsc,
            actionDelay: actionDelay,
            recordingPath: recordingPath,
            restoreClipboard: restoreClipboard,
            shouldStopMonitoringAfterAction: options.isLastInChain,
            shouldTriggerCleanupAfterAction: options.isLastInChain,
            restoreClipboardIndependentlyOfEsc: options.isLastInChain,
            restoreClipboardDelay: restoreDelay,
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
        let enhancedMetaJson = enhanceMetaJsonWithSessionData(metaJson: metaJson, recordingPath: recordingPath, actionTemplate: ascript.action)
        
        let baseShouldEsc = !(ascript.noEsc ?? configManager.config.defaults.noEsc)
        let shouldEsc = options.isFirstInChain ? baseShouldEsc : false
        let actionDelay = ascript.actionDelay ?? configManager.config.defaults.actionDelay
        let effectiveScriptAsync = ascript.scriptAsync ?? configManager.config.defaults.scriptAsync ?? true
        let effectiveScriptWaitTimeout = ascript.scriptWaitTimeout ?? configManager.config.defaults.scriptWaitTimeout ?? 3.0
        
        // Only the last action controls clipboard restoration decision.
        let restoreClipboard = options.isLastInChain ? (ascript.restoreClipboard ?? configManager.config.defaults.restoreClipboard) : false
        let restoreDelay = options.isLastInChain
            ? (ascript.restoreClipboardDelay ?? configManager.config.defaults.restoreClipboardDelay ?? 0.3)
            : (configManager.config.defaults.restoreClipboardDelay ?? 0.3)
        
        clipboardMonitor.executeNonInsertActionWithClipboardRestore(
            action: { [weak self] in
                self?.processAppleScriptAction(
                    ascript,
                    metaJson: enhancedMetaJson,
                    recordingPath: recordingPath,
                    scriptAsync: effectiveScriptAsync,
                    scriptWaitTimeout: effectiveScriptWaitTimeout
                ) ?? false
            },
            shouldEsc: shouldEsc,
            actionDelay: actionDelay,
            recordingPath: recordingPath,
            restoreClipboard: restoreClipboard,
            shouldStopMonitoringAfterAction: options.isLastInChain,
            shouldTriggerCleanupAfterAction: options.isLastInChain,
            restoreClipboardIndependentlyOfEsc: options.isLastInChain,
            restoreClipboardDelay: restoreDelay,
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
        let normalizedActionLevel = actionLevel?.trimmingCharacters(in: .whitespacesAndNewlines)

        if isFirstStep {
            if let normalizedActionLevel {
                if normalizedActionLevel == actionName {
                    return normalizedActionLevel.isEmpty ? nil : normalizedActionLevel
                }
                return normalizedActionLevel.isEmpty ? nil : normalizedActionLevel
            }
            let defaultsNext = configManager.config.defaults.nextAction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return defaultsNext.isEmpty ? nil : defaultsNext
        }

        // Never re-apply defaults.nextAction after first action.
        if normalizedActionLevel == actionName {
            return (normalizedActionLevel ?? "").isEmpty ? nil : normalizedActionLevel
        }
        return (normalizedActionLevel ?? "").isEmpty ? nil : normalizedActionLevel
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
    
    /// Enhances metaJson with session data from clipboard monitor and chain-frozen app context placeholders.
    private func enhanceMetaJsonWithSessionData(metaJson: [String: Any], recordingPath: String, actionTemplate: String) -> [String: Any] {
        var enhanced = metaJson
        let contextRecordingPath = clipboardMonitor.getContextRootRecordingPath(for: recordingPath)
        
        let existingSelectedText = (metaJson["selectedText"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if existingSelectedText.isEmpty {
            // Get selected text that was captured when recording session started
            let sessionSelectedText = clipboardMonitor.getSessionSelectedText(for: contextRecordingPath)
            if !sessionSelectedText.isEmpty {
                enhanced["selectedText"] = sessionSelectedText
            }
        }
        
        let existingClipboardContext = (metaJson["clipboardContext"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if existingClipboardContext.isEmpty {
            // Get clipboard content for the clipboardContext placeholder with stacking support
            let swResult = (metaJson["llmResult"] as? String) ?? (metaJson["result"] as? String) ?? ""
            let enableStacking = configManager.config.defaults.clipboardStacking
            let sessionClipboardContent = clipboardMonitor.getSessionClipboardContentWithStacking(
                for: contextRecordingPath,
                swResult: swResult,
                enableStacking: enableStacking
            )
            if !sessionClipboardContent.isEmpty {
                enhanced["clipboardContext"] = sessionClipboardContent
            }
        }

        let scriptResults = clipboardMonitor.getScriptResults(for: recordingPath)
        if let firstResult = scriptResults.first, !firstResult.isEmpty {
            enhanced["actionResult"] = firstResult
        }
        if !scriptResults.isEmpty {
            enhanced["actionResults"] = scriptResults
        }

        var snapshot = getChainContextSnapshot(recordingPath: recordingPath)
        if snapshot.frontAppName.isEmpty {
            snapshot.frontAppName = (metaJson["frontAppName"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        if snapshot.frontAppBundleId.isEmpty {
            snapshot.frontAppBundleId = (metaJson["frontAppBundleId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        if snapshot.frontAppPid == nil {
            snapshot.frontAppPid = extractFrontAppPid(from: metaJson)
        }

        enhanced["frontAppName"] = snapshot.frontAppName
        enhanced["frontAppBundleId"] = snapshot.frontAppBundleId
        enhanced["frontApp"] = snapshot.frontAppName
        if let frontAppPid = snapshot.frontAppPid {
            enhanced["frontAppPid"] = Int(frontAppPid)
        }

        if actionUsesPlaceholder(actionTemplate, key: "appContext") {
            if !snapshot.didResolveAppContext {
                snapshot.appContext = getAppContext(
                    targetPid: snapshot.frontAppPid,
                    fallbackAppName: snapshot.frontAppName
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                snapshot.didResolveAppContext = true
            }
            enhanced["appContext"] = snapshot.appContext
        }

        if actionUsesPlaceholder(actionTemplate, key: "appVocabulary") {
            if !snapshot.didResolveAppVocabulary {
                snapshot.appVocabulary = getAppVocabulary(
                    targetPid: snapshot.frontAppPid,
                    fallbackAppName: snapshot.frontAppName,
                    fallbackBundleId: snapshot.frontAppBundleId
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                snapshot.didResolveAppVocabulary = true
            }
            enhanced["appVocabulary"] = snapshot.appVocabulary
        }

        setChainContextSnapshot(snapshot, recordingPath: recordingPath)
        
        return enhanced
    }

    private func initializeChainContextSnapshot(recordingPath: String, metaJson: [String: Any]) {
        let snapshotKey = chainSnapshotKey(for: recordingPath)
        var shouldInitializeSnapshot = false
        chainContextQueue.sync {
            let currentCount = chainContextRefCountByRecordingPath[snapshotKey] ?? 0
            chainContextRefCountByRecordingPath[snapshotKey] = currentCount + 1
            shouldInitializeSnapshot = chainContextByRecordingPath[snapshotKey] == nil
        }
        if !shouldInitializeSnapshot {
            return
        }

        let snapshot = ChainContextSnapshot(
            frontAppName: (metaJson["frontAppName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            frontAppBundleId: (metaJson["frontAppBundleId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            frontAppPid: extractFrontAppPid(from: metaJson),
            didResolveAppContext: false,
            appContext: "",
            didResolveAppVocabulary: false,
            appVocabulary: ""
        )
        setChainContextSnapshot(snapshot, recordingPath: snapshotKey)
    }

    private func clearChainContextSnapshot(recordingPath: String) {
        let snapshotKey = chainSnapshotKey(for: recordingPath)
        chainContextQueue.sync {
            let currentCount = chainContextRefCountByRecordingPath[snapshotKey] ?? 0
            if currentCount <= 1 {
                chainContextRefCountByRecordingPath.removeValue(forKey: snapshotKey)
                chainContextByRecordingPath.removeValue(forKey: snapshotKey)
            } else {
                chainContextRefCountByRecordingPath[snapshotKey] = currentCount - 1
            }
        }
    }

    private func getChainContextSnapshot(recordingPath: String) -> ChainContextSnapshot {
        let snapshotKey = chainSnapshotKey(for: recordingPath)
        return chainContextQueue.sync {
            chainContextByRecordingPath[snapshotKey] ?? ChainContextSnapshot(
                frontAppName: "",
                frontAppBundleId: "",
                frontAppPid: nil,
                didResolveAppContext: false,
                appContext: "",
                didResolveAppVocabulary: false,
                appVocabulary: ""
            )
        }
    }

    private func setChainContextSnapshot(_ snapshot: ChainContextSnapshot, recordingPath: String) {
        let snapshotKey = chainSnapshotKey(for: recordingPath)
        chainContextQueue.sync {
            chainContextByRecordingPath[snapshotKey] = snapshot
        }
    }

    private func chainSnapshotKey(for recordingPath: String) -> String {
        clipboardMonitor.getContextRootRecordingPath(for: recordingPath)
    }

    private func extractFrontAppPid(from metaJson: [String: Any]) -> Int32? {
        if let value = metaJson["frontAppPid"] as? Int32 {
            return value
        }
        if let value = metaJson["frontAppPid"] as? Int {
            return Int32(value)
        }
        if let value = metaJson["frontAppPid"] as? NSNumber {
            return Int32(value.intValue)
        }
        if let value = metaJson["frontAppPid"] as? String, let parsed = Int(value) {
            return Int32(parsed)
        }
        return nil
    }

    private func actionUsesPlaceholder(_ actionTemplate: String, key: String) -> Bool {
        guard actionTemplate.contains("{{"), actionTemplate.contains(key) else {
            return false
        }
        return true
    }
    
    // MARK: - Action Processing Methods
    
    private func processUrlAction(_ urlAction: AppConfiguration.Url, metaJson: [String: Any]) -> Bool {
        // Process the URL action with both XML and dynamic placeholders
        // Placeholders are now URL-encoded individually during processing
        let processedAction = processAllPlaceholders(action: urlAction.action, metaJson: metaJson, actionType: .url).text

        let normalized = processedAction.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || normalized == ".none" {
            logDebug("[UrlAction] Action is empty or '.none' - skipping URL execution")
            return true
        }
        
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
    
    private func processShortcutAction(
        _ shortcut: AppConfiguration.Shortcut,
        shortcutName: String,
        metaJson: [String: Any],
        recordingPath: String,
        scriptAsync: Bool,
        scriptWaitTimeout: TimeInterval
    ) -> Bool {
        let processedAction = processAllPlaceholders(action: shortcut.action, metaJson: metaJson, actionType: .shortcut).text
        
        logDebug("[ShortcutAction] Processed action before sending to shortcuts: \(redactForLogs(processedAction))")
        
        let normalized = processedAction.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == ".run" {
            logDebug("[ShortcutAction] Action is '.run' - running shortcut without input")

            let task = Process()
            task.launchPath = "/usr/bin/shortcuts"
            task.arguments = ["run", shortcutName]
            task.environment = getUTF8Environment()
            return executeScriptTask(
                task,
                recordingPath: recordingPath,
                scriptAsync: scriptAsync,
                scriptWaitTimeout: scriptWaitTimeout,
                logPrefix: "ShortcutAction"
            )
        } else if normalized.isEmpty || normalized == ".none" {
            logDebug("[ShortcutAction] Action is empty or '.none' - skipping shortcut execution")
            return true
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

                let success = executeScriptTask(
                    task,
                    recordingPath: recordingPath,
                    scriptAsync: scriptAsync,
                    scriptWaitTimeout: scriptWaitTimeout,
                    logPrefix: "ShortcutAction"
                )
                
                // Clean up the temporary file after a short delay to ensure shortcuts has read it
                DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                    do {
                        try FileManager.default.removeItem(atPath: tempFile)
                        logDebug("[ShortcutAction] Cleaned up temporary file: \(tempFile)")
                    } catch {
                        logWarning("[ShortcutAction] Failed to clean up temporary file \(tempFile): \(error)")
                    }
                }
                return success
            } catch {
                logError("Failed to execute shortcut action: \(error)")
                // Clean up temp file on error
                try? FileManager.default.removeItem(atPath: tempFile)
                return false
            }
        }
        // ESC simulation and action delay are now handled by ClipboardMonitor
    }
    
    private func processShellScriptAction(
        _ shell: AppConfiguration.ScriptShell,
        metaJson: [String: Any],
        recordingPath: String,
        scriptAsync: Bool,
        scriptWaitTimeout: TimeInterval
    ) -> Bool {
        let processedAction = processAllPlaceholders(action: shell.action, metaJson: metaJson, actionType: .shell).text
        let normalized = processedAction.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || normalized == ".none" {
            logDebug("[ShellAction] Action is empty or '.none' - skipping shell execution")
            return true
        }
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", processedAction]
        task.environment = getUTF8Environment()
        return executeScriptTask(
            task,
            recordingPath: recordingPath,
            scriptAsync: scriptAsync,
            scriptWaitTimeout: scriptWaitTimeout,
            logPrefix: "ShellAction"
        )
        // ESC simulation and action delay are now handled by ClipboardMonitor
    }
    
    private func processAppleScriptAction(
        _ ascript: AppConfiguration.ScriptAppleScript,
        metaJson: [String: Any],
        recordingPath: String,
        scriptAsync: Bool,
        scriptWaitTimeout: TimeInterval
    ) -> Bool {
        let processedAction = processAllPlaceholders(action: ascript.action, metaJson: metaJson, actionType: .appleScript).text
        let normalized = processedAction.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || normalized == ".none" {
            logDebug("[AppleScriptAction] Action is empty or '.none' - skipping AppleScript execution")
            return true
        }
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", processedAction]
        task.environment = getUTF8Environment()
        return executeScriptTask(
            task,
            recordingPath: recordingPath,
            scriptAsync: scriptAsync,
            scriptWaitTimeout: scriptWaitTimeout,
            logPrefix: "AppleScriptAction"
        )
        // ESC simulation and action delay are now handled by ClipboardMonitor
    }

    private func executeScriptTask(
        _ task: Process,
        recordingPath: String,
        scriptAsync: Bool,
        scriptWaitTimeout: TimeInterval,
        logPrefix: String
    ) -> Bool {
        let stdoutPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            if scriptAsync {
                logDebug("[\(logPrefix)] Script launched asynchronously")
                return true
            }

            let timeout = max(0.1, scriptWaitTimeout)
            let deadline = Date().addingTimeInterval(timeout)
            while task.isRunning {
                if Date() >= deadline {
                    task.terminate()
                    logError("[\(logPrefix)] Script wait timed out after \(timeout)s")
                    return false
                }
                Thread.sleep(forTimeInterval: 0.02)
            }

            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty {
                clipboardMonitor.appendScriptResult(output, for: recordingPath)
            }
            return task.terminationStatus == 0
        } catch {
            logError("[\(logPrefix)] Failed to execute script: \(error)")
            return false
        }
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
        if let activeInsert = activeInsert {
            if let insertMoveTo = activeInsert.moveTo {
                moveTo = insertMoveTo
            } else {
                moveTo = configManager.config.defaults.moveTo
            }
        } else {
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
            if let actionMoveTo = url.moveTo {
                moveTo = actionMoveTo
            } else {
                moveTo = configManager.config.defaults.moveTo
            }
        } else if let shortcut = action as? AppConfiguration.Shortcut {
            if let actionMoveTo = shortcut.moveTo {
                moveTo = actionMoveTo
            } else {
                moveTo = configManager.config.defaults.moveTo
            }
        } else if let shell = action as? AppConfiguration.ScriptShell {
            if let actionMoveTo = shell.moveTo {
                moveTo = actionMoveTo
            } else {
                moveTo = configManager.config.defaults.moveTo
            }
        } else if let ascript = action as? AppConfiguration.ScriptAppleScript {
            if let actionMoveTo = ascript.moveTo {
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
