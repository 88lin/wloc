import Foundation

/// 两端高级锁定共用的参数，默认值与普通锁定一致。
struct AppWLocLockParameters {
    static let defaultHorizontalAccuracy: Int64 = 4
    static let defaultVerticalAccuracy: Int64 = 10

    var altitude: Double = 480
    var horizontalAccuracy: Int64 = AppWLocLockParameters.defaultHorizontalAccuracy
    var verticalAccuracy: Int64 = AppWLocLockParameters.defaultVerticalAccuracy

    /// 再次打开表单时，优先显示上次锁定使用的参数。
    init(state: AppWLocLockState? = nil) {
        if let state {
            altitude = state.altitude
            horizontalAccuracy = state.horizontalAccuracy
            verticalAccuracy = state.verticalAccuracy
        }
    }

    /// 先校验输入，避免无效数字或超出协议范围的海拔进入锁定状态。
    init(altitudeText: String, horizontalAccuracyText: String, verticalAccuracyText: String) throws {
        guard let altitude = Double(altitudeText.trimmingCharacters(in: .whitespacesAndNewlines)),
              altitude.isFinite,
              altitude >= Double(Int64.min), altitude < Double(Int64.max) else {
            throw AppWLocParameterError.invalidValue("海拔高度请输入有效数字，可为负数。")
        }
        guard let horizontal = Int64(horizontalAccuracyText.trimmingCharacters(in: .whitespacesAndNewlines)), horizontal >= 0 else {
            throw AppWLocParameterError.invalidValue("水平精度请输入非负整数，单位为米。")
        }
        guard let vertical = Int64(verticalAccuracyText.trimmingCharacters(in: .whitespacesAndNewlines)), vertical >= 0 else {
            throw AppWLocParameterError.invalidValue("垂直精度请输入非负整数，单位为米。")
        }
        self.altitude = altitude
        horizontalAccuracy = horizontal
        verticalAccuracy = vertical
    }
}

enum AppWLocParameterError: Error, LocalizedError {
    case invalidValue(String)
    case elevationUnavailable
    case elevationRequestFailed

    var errorDescription: String? {
        switch self {
        case .invalidValue(let message): return message
        case .elevationUnavailable: return "该位置暂无海拔数据，请手动填写海拔高度。"
        case .elevationRequestFailed: return "海拔查询失败，请稍后重试或手动填写。"
        }
    }
}

enum AppWLocElevationQuery {
    private struct Response: Decodable {
        struct Point: Decodable {
            let elevation: Double?
        }
        let status: String
        let results: [Point]?
    }

    /// 用真实的 WGS-84 坐标查询海拔；结果回到主线程，关闭表单时可取消请求。
    @discardableResult
    static func query(latitude: Double, longitude: Double, completion: @escaping (Result<Double, Error>) -> Void) -> URLSessionDataTask {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.opentopodata.org"
        components.path = "/v1/aster30m"
        components.queryItems = [URLQueryItem(name: "locations", value: "\(latitude),\(longitude)")]
        let request = URLRequest(url: components.url!, timeoutInterval: 15)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<Double, Error>
            if let error {
                result = .failure(error)
            } else if let response = response as? HTTPURLResponse, response.statusCode == 200,
                      let data, let decoded = try? JSONDecoder().decode(Response.self, from: data), decoded.status == "OK" {
                if let elevation = decoded.results?.first?.elevation, elevation.isFinite {
                    result = .success(elevation)
                } else {
                    result = .failure(AppWLocParameterError.elevationUnavailable)
                }
            } else {
                result = .failure(AppWLocParameterError.elevationRequestFailed)
            }
            DispatchQueue.main.async { completion(result) }
        }
        task.resume()
        return task
    }
}

/// WLoc 使用的锁定点状态。
struct AppWLocLockState: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var altitude: Double
    var horizontalAccuracy: Int64
    var verticalAccuracy: Int64
    var updatedAt: Date

    /// 未指定精度时，使用普通锁定和高级锁定共用的默认值。
    init(
        latitude: Double,
        longitude: Double,
        altitude: Double = 480,
        horizontalAccuracy: Int64 = AppWLocLockParameters.defaultHorizontalAccuracy,
        verticalAccuracy: Int64 = AppWLocLockParameters.defaultVerticalAccuracy,
        updatedAt: Date = Date()
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.updatedAt = updatedAt
    }
}

enum AppWLocStateStoreError: Error, LocalizedError {
    case invalidCoordinate
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .invalidCoordinate:
            return "\(AppWLocConfig.displayName) 锁定坐标无效"
        case .encodeFailed:
            return "\(AppWLocConfig.displayName) 状态保存失败"
        }
    }
}

final class AppWLocStateStore {
    static let shared = AppWLocStateStore()

    private let key = "AppWLoc.lockState.v1"
    private let defaults: UserDefaults

    init() {
        let defaults = UserDefaults(suiteName: AppWLocConfig.defaultsSuiteName)
        self.defaults = defaults ?? .standard
        #if os(iOS)
        AppWLocUtils.debugLog(
            "\(AppWLocConfig.displayName) 状态存储 suite=\(AppWLocConfig.defaultsSuiteName ?? "<standard>")"
                + " opened=\(defaults != nil)"
        )
        #endif
    }

    func save(_ state: AppWLocLockState) throws {
        guard (-90...90).contains(state.latitude),
              (-180...180).contains(state.longitude) else {
            throw AppWLocStateStoreError.invalidCoordinate
        }
        guard let data = try? JSONEncoder().encode(state) else {
            throw AppWLocStateStoreError.encodeFailed
        }
        defaults.set(data, forKey: key)
        defaults.synchronize()

        AppWLocUtils.debugLog("锁定位置 lat：\(state.latitude)，lng：\(state.longitude)， alt：\(state.altitude)")
    }

    /// 保存锁定位置；调用方没有传精度时，使用统一的默认值。
    func lock(
        latitude: Double,
        longitude: Double,
        altitude: Double = 480,
        horizontalAccuracy: Int64 = AppWLocLockParameters.defaultHorizontalAccuracy,
        verticalAccuracy: Int64 = AppWLocLockParameters.defaultVerticalAccuracy
    ) throws {
        try save(AppWLocLockState(
            latitude: latitude,
            longitude: longitude,
            altitude: altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: verticalAccuracy
        ))
    }

    func clear() {
        defaults.removeObject(forKey: key)
        defaults.synchronize()
    }

    func load() -> AppWLocLockState? {
        guard let data = defaults.data(forKey: key) else {
            AppWLocUtils.debugLog("\(AppWLocConfig.displayName) 未读取到锁定坐标")
            return nil
        }
        guard let state = try? JSONDecoder().decode(AppWLocLockState.self, from: data) else {
            AppWLocUtils.debugLog("\(AppWLocConfig.displayName) 锁定坐标解码失败")
            return nil
        }
        AppWLocUtils.debugLog(
            "\(AppWLocConfig.displayName) 已读取锁定坐标 lat=\(state.latitude), lng=\(state.longitude)"
        )
        return state
    }
}
