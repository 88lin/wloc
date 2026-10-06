import AppKit
import CryptoKit
import Security

/// 下载和检查更新包，使用 macOS 原生授权替换应用并重新启动。
final class WLocMacUpdateInstaller: NSObject, URLSessionDownloadDelegate {
    private let update: AppWLocAvailableUpdate
    private let directory: URL
    private var session: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var preparedApplication: URL?
    private var replacementDirectory: URL?
    private var progress: ((Double?, String) -> Void)?
    private var completion: ((Result<Void, Error>) -> Void)?
    private var isCancelled = false
    private var isInstalling = false
    private var preserveBackup = false

    private enum InstallError: LocalizedError {
        case invalidPackage
        case invalidApplication
        case invalidSignature
        case operationFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidPackage: return "安装包不完整或校验失败，请重新下载。"
            case .invalidApplication: return "安装包中的应用标识或版本不匹配，无法安装。"
            case .invalidSignature: return "安装包中的应用签名校验失败，无法安装。"
            case .operationFailed(let message): return message
            }
        }
    }

    /// 每次更新使用独立的私有临时目录，取消或失败后清理本次下载。
    init(update: AppWLocAvailableUpdate) throws {
        self.update = update
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("WLocUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        super.init()
    }

    /// 下载只接受此项目的 HTTPS Release DMG，浏览器发布页不会被当作安装包。
    func download(progress: @escaping (Double?, String) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        self.progress = progress
        self.completion = completion
        guard update.assetName?.lowercased().hasSuffix(".dmg") == true,
              update.downloadURL.scheme == "https", update.downloadURL.host == "github.com",
              update.downloadURL.path.hasPrefix("/\(AppWLocConfig.githubRepository)/releases/download/") else {
            finish(.failure(InstallError.invalidPackage))
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        var request = URLRequest(url: update.downloadURL)
        request.setValue("WLoc8.com/\(AppWLocConfig.currentVersion)", forHTTPHeaderField: "User-Agent")
        downloadTask = session?.downloadTask(with: request)
        progress(nil, "正在下载 v\(update.version)…")
        downloadTask?.resume()
    }

    /// 下载和校验可以取消；安装期间保留回滚所需的文件。
    func cancel() {
        guard !isInstalling, !preserveBackup else { return }
        isCancelled = true
        if let downloadTask {
            downloadTask.cancel()
        } else if completion == nil {
            removeTemporaryFiles()
        }
    }

    /// 回报下载进度，未知总长度时让界面保持等待状态。
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = update.assetSize ?? totalBytesExpectedToWrite
        let fraction = total > 0 ? min(1, Double(totalBytesWritten) / Double(total)) : nil
        progress?(fraction, "正在下载 v\(update.version)…")
    }

    /// 先把系统临时文件移到本次更新目录，再到后台校验和挂载，避免阻塞界面。
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard !isCancelled else { finish(.failure(URLError(.cancelled))); return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
                throw InstallError.operationFailed("下载失败，请检查网络后重试。")
            }
            let image = directory.appendingPathComponent("update.dmg")
            try FileManager.default.moveItem(at: location, to: image)
            self.downloadTask = nil
            progress?(nil, "正在校验安装包…")
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try self.prepareApplication(from: image) }
                DispatchQueue.main.async {
                    if self.isCancelled {
                        self.finish(.failure(URLError(.cancelled)))
                    } else {
                        switch result {
                        case .success(let application):
                            self.preparedApplication = application
                            self.finish(.success(()))
                        case .failure(let error): self.finish(.failure(error))
                        }
                    }
                }
            }
        } catch { finish(.failure(error)) }
    }

    /// 网络错误也走同一个结束入口，保证只回调一次。
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    /// 结束下载阶段并断开 delegate 引用；成功时保留已检查的应用供安装使用。
    private func finish(_ result: Result<Void, Error>) {
        guard let completion else { return }
        self.completion = nil
        session?.finishTasksAndInvalidate()
        session = nil
        downloadTask = nil
        if case .failure = result { removeTemporaryFiles() }
        completion(result)
    }

    /// 安装目录和下载目录可能位于不同磁盘，结束后分别清理。
    private func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: directory)
        if let replacementDirectory { try? FileManager.default.removeItem(at: replacementDirectory) }
    }

    /// 检查下载长度和 SHA-256，只读挂载后复制出应用，随后卸载镜像。
    private func prepareApplication(from image: URL) throws -> URL {
        let attributes = try FileManager.default.attributesOfItem(atPath: image.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0, update.assetSize == nil || size == update.assetSize else { throw InstallError.invalidPackage }
        if let digest = update.assetDigest {
            guard digest.lowercased().hasPrefix("sha256:") else { throw InstallError.invalidPackage }
            let handle = try FileHandle(forReadingFrom: image)
            defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
            let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == String(digest.dropFirst(7)).lowercased() else { throw InstallError.invalidPackage }
        }
        let mount = directory.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        _ = try Self.run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path])
        defer { _ = try? Self.run("/usr/bin/hdiutil", ["detach", mount.path]) }
        let applications = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "app" }
        guard applications.count == 1, let application = applications.first else { throw InstallError.invalidApplication }
        let prepared = directory.appendingPathComponent("WLoc8.com.app", isDirectory: true)
        _ = try Self.run("/usr/bin/ditto", [application.path, prepared.path])
        try validateApplication(prepared)
        return prepared
    }

    /// 应用必须是同一 Bundle ID 和目标版本，并通过完整签名校验；正式版还检查同一签名团队。
    private func validateApplication(_ url: URL) throws {
        guard let bundle = Bundle(url: url), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !AppWLocUpdateChecker.isVersion(version, newerThan: update.version),
              !AppWLocUpdateChecker.isVersion(update.version, newerThan: version),
              let executable = bundle.executableURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw InstallError.invalidApplication
        }
        var code: SecStaticCode?
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else { throw InstallError.invalidSignature }
        if let expectedTeam = AppWLocPrivilegedHelperConstants.currentTeamIdentifier {
            var information: CFDictionary?
            guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
                  let values = information as? [String: Any], values[kSecCodeInfoTeamIdentifier as String] as? String == expectedTeam else {
                throw InstallError.invalidSignature
            }
        }
    }

    /// 先停止定位修改后再调用此方法；目录不可写时使用系统的文件替换授权。
    func install(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let preparedApplication, !isCancelled else { completion(.failure(URLError(.cancelled))); return }
        isInstalling = true
        progress?(nil, "正在安装，完成后自动重启…")
        let current = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let destination = current.path.hasPrefix("/Volumes/") || current.path.contains("/AppTranslocation/")
            ? URL(fileURLWithPath: "/Applications/WLoc8.com.app") : current
        guard destination.pathExtension == "app", FileManager.default.fileExists(atPath: destination.path) else {
            isInstalling = false
            completion(.failure(InstallError.operationFailed("请先将应用拖到“应用程序”文件夹，再使用在线更新。")))
            return
        }
        let needsAuthorization = !FileManager.default.isWritableFile(atPath: destination.path)
            || !FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path)
        if needsAuthorization {
            NSWorkspace.shared.requestAuthorization(to: .replaceFile) { authorization, error in
                DispatchQueue.main.async {
                    guard let authorization else {
                        self.isInstalling = false
                        completion(.failure(error ?? URLError(.cancelled)))
                        return
                    }
                    self.replaceAndRelaunch(preparedApplication, destination: destination,
                                            manager: FileManager(authorization: authorization), completion: completion)
                }
            }
        } else {
            replaceAndRelaunch(preparedApplication, destination: destination, manager: .default, completion: completion)
        }
    }

    /// 保存完整旧版后原子替换；确认新进程已启动，再让当前应用退出。
    private func replaceAndRelaunch(_ application: URL, destination: URL, manager: FileManager, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var backup: URL?
            var backupReady = false
            do {
                guard let installed = Bundle(url: destination), installed.bundleIdentifier == Bundle.main.bundleIdentifier,
                      let version = installed.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                      AppWLocUpdateChecker.isVersion(self.update.version, newerThan: version) else {
                    throw InstallError.operationFailed("应用目录中的版本已经更新或应用标识不匹配，请重新检查更新。")
                }
                // 原子替换要求处于同一磁盘；新版本和完整旧版备份都放在目标磁盘的私有目录。
                let replacement = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
                self.replacementDirectory = replacement
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: replacement.path)
                let staged = replacement.appendingPathComponent("update.app", isDirectory: true)
                let saved = replacement.appendingPathComponent("previous.app", isDirectory: true)
                backup = saved
                _ = try Self.run("/usr/bin/ditto", [application.path, staged.path])
                _ = try Self.run("/usr/bin/ditto", [destination.path, saved.path])
                backupReady = true
                _ = try manager.replaceItemAt(destination, withItemAt: staged, options: .usingNewMetadataOnly)
                DispatchQueue.main.async {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.createsNewApplicationInstance = true
                    configuration.activates = true
                    NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { runningApplication, error in
                        if error == nil, let runningApplication,
                           runningApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                           !runningApplication.isTerminated {
                            DispatchQueue.main.async {
                                self.isInstalling = false
                                self.removeTemporaryFiles()
                                completion(.success(()))
                            }
                        } else {
                            self.restoreBackup(saved, destination: destination, manager: manager,
                                               error: error ?? InstallError.operationFailed("新版本未能启动。"), completion: completion)
                        }
                    }
                }
            } catch {
                // 复制中断留下的备份不完整，不能用它覆盖仍可运行的旧版。
                if backupReady, let backup {
                    self.restoreBackup(backup, destination: destination, manager: manager, error: error, completion: completion)
                } else {
                    DispatchQueue.main.async {
                        self.isInstalling = false
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    /// 替换或启动失败时恢复已保存的旧版；恢复失败时保留备份供用户取回。
    private func restoreBackup(_ backup: URL, destination: URL, manager: FileManager, error: Error, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { _ = try manager.replaceItemAt(destination, withItemAt: backup, options: .usingNewMetadataOnly) }
            DispatchQueue.main.async {
                self.isInstalling = false
                if case .failure = result {
                    self.preserveBackup = true
                    completion(.failure(InstallError.operationFailed("更新失败，旧版备份保存在：\(backup.path)\n\n\(error.localizedDescription)")))
                } else {
                    completion(.failure(InstallError.operationFailed("更新失败，已恢复旧版本。\n\n\(error.localizedDescription)")))
                }
            }
        }
    }

    /// 系统工具在后台执行，保留错误信息供界面显示。
    private static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "更新处理失败，请重试。"
            throw InstallError.operationFailed(message)
        }
        return data
    }
}
