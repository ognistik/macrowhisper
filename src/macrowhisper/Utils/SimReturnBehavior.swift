import Foundation

struct SimReturnBehavior: Equatable {
    let shouldPressReturn: Bool
    let delay: TimeInterval
    let logMessage: String?
    let clearsAutoReturn: Bool
}

enum SimReturnBehaviorResolver {
    static func resolve(
        actionSimReturn: Bool?,
        defaultSimReturn: Bool,
        returnDelay: TimeInterval,
        autoReturnEnabled: Bool
    ) -> SimReturnBehavior {
        let shouldSimReturn = actionSimReturn ?? defaultSimReturn

        if autoReturnEnabled {
            let logMessage = shouldSimReturn
                ? "Simulating return key press due to simReturn setting (auto-return was also set)"
                : "Simulating return key press due to auto-return"
            return SimReturnBehavior(
                shouldPressReturn: true,
                delay: returnDelay,
                logMessage: logMessage,
                clearsAutoReturn: true
            )
        }

        if shouldSimReturn {
            return SimReturnBehavior(
                shouldPressReturn: true,
                delay: returnDelay,
                logMessage: "Simulating return key press due to simReturn setting",
                clearsAutoReturn: false
            )
        }

        return SimReturnBehavior(
            shouldPressReturn: false,
            delay: returnDelay,
            logMessage: nil,
            clearsAutoReturn: false
        )
    }

    static func perform(
        _ behavior: SimReturnBehavior,
        sleep: (TimeInterval) -> Void,
        log: (String) -> Void,
        postReturn: () -> Void,
        clearAutoReturn: () -> Void
    ) {
        guard behavior.shouldPressReturn else {
            if behavior.clearsAutoReturn {
                clearAutoReturn()
            }
            return
        }

        if let logMessage = behavior.logMessage {
            log(logMessage)
        }
        if behavior.delay > 0 {
            sleep(behavior.delay)
        }
        postReturn()

        if behavior.clearsAutoReturn {
            clearAutoReturn()
        }
    }
}
