import Foundation

struct LoginItemManager {
    let appURL: URL
    let agentURL: URL
    init(appURL: URL = Bundle.main.bundleURL,
         agentURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/com.jesseyun.KeepAwake.login.plist")) {
        self.appURL = appURL; self.agentURL = agentURL
    }
    var exists: Bool { FileManager.default.fileExists(atPath: agentURL.path) }
    var matchesCurrentApp: Bool {
        guard let data = try? Data(contentsOf: agentURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["Label"] as? String == "com.jesseyun.KeepAwake.login",
              let args = plist["ProgramArguments"] as? [String], args == ["/usr/bin/open", appURL.path] else { return false }
        return FileManager.default.fileExists(atPath: appURL.path)
    }
    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard appURL.pathExtension == "app", FileManager.default.fileExists(atPath: appURL.path) else {
                throw DisplayControlError(message: "请从已安装的 Keep Awake.app 启动后再设置登录启动")
            }
            try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let content: [String: Any] = ["Label": "com.jesseyun.KeepAwake.login", "ProgramArguments": ["/usr/bin/open", appURL.path], "RunAtLoad": true, "LimitLoadToSessionType": "Aqua"]
            try PropertyListSerialization.data(fromPropertyList: content, format: .xml, options: 0).write(to: agentURL, options: .atomic)
        } else if exists { try FileManager.default.removeItem(at: agentURL) }
    }
}
