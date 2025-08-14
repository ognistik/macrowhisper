import Foundation

class NotificationManager {
    func sendNotification(title: String, body: String) {
        // Just log instead if notifications aren't available
        print("NOTIFICATION: \(title) - \(body)")
        
        // Use AppleScript for notifications
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedBody = body.replacingOccurrences(of: "\"", with: "\\\"")
        
        let script = "display notification \"\(escapedBody)\" with title \"\(escapedTitle)\""
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        try? task.run()
    }
}

func notify(title: String, message: String) {
    if !globalState.disableNotifications {
            notificationManager.sendNotification(title: title, body: message)
        }
} 