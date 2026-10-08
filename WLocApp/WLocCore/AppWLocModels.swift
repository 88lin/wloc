import CoreLocation
import Foundation
import MapKit

struct AppWLocPlace: Codable, Equatable {
    var id: UUID
    var name: String
    var detail: String
    var latitude: Double
    var longitude: Double
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        detail: String = "",
        latitude: Double,
        longitude: Double,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.latitude = latitude
        self.longitude = longitude
        self.createdAt = createdAt
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var coordinateText: String {
        String(format: "%.6f, %.6f", latitude, longitude)
    }

    init(mapItem: MKMapItem) {
        let placemark = mapItem.placemark
        let mapAddress = placemark.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(
            name: mapItem.name ?? placemark.name ?? "未命名地点",
            detail: mapAddress.isEmpty ? Self.detailedAddress(from: placemark) : mapAddress,
            latitude: placemark.coordinate.latitude,
            longitude: placemark.coordinate.longitude
        )
    }

    static func detailedAddress(from placemark: CLPlacemark) -> String {
        // CLPlacemark 没有跨系统版本稳定的单一格式化地址，按行政区到门牌逐级组合，
        // 并去重，确保收藏保存的是可读详细地址，而不只是城市或经纬度。
        let components = [
            placemark.country,
            placemark.administrativeArea,
            placemark.locality,
            placemark.subLocality,
            placemark.thoroughfare,
            placemark.subThoroughfare,
            placemark.postalCode
        ]
        var seen = Set<String>()
        return components
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: " ")
    }
}

struct AppWLocFavorite: Codable, Equatable {
    var id: UUID
    var alias: String
    var title: String
    var detail: String
    var latitude: Double
    var longitude: Double
    var createdAt: Date

    init(
        id: UUID = UUID(),
        alias: String,
        title: String,
        detail: String,
        latitude: Double,
        longitude: Double,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.alias = alias
        self.title = title
        self.detail = detail
        self.latitude = latitude
        self.longitude = longitude
        self.createdAt = createdAt
    }

    /// 收藏只保存实际地点信息，查询状态和引导文案不作为名称、地址保存。
    init(place: AppWLocPlace, alias: String) {
        self.init(
            alias: alias.trimmingCharacters(in: .whitespacesAndNewlines),
            title: place.name.trimmingCharacters(in: .whitespacesAndNewlines),
            detail: place.detail.trimmingCharacters(in: .whitespacesAndNewlines),
            latitude: place.latitude,
            longitude: place.longitude
        )
        title = displayTitle
        detail = displayDetail
    }

    var place: AppWLocPlace {
        AppWLocPlace(
            id: id,
            name: displayTitle,
            detail: displayDetail,
            latitude: latitude,
            longitude: longitude,
            createdAt: createdAt
        )
    }

    var displayAlias: String {
        alias.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 两端共用名称规则，不把查询状态或坐标选点提示展示成地点名称。
    var displayTitle: String {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["查询中...", "查询中…", "自定义位置", "经纬度位置", "未命名地点"].contains(value) ? "" : value
    }

    /// 没有实际地址时保持为空，列表和收藏弹窗均不补占位文案。
    var displayDetail: String {
        let value = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["暂无详细地址", "单击地图可选择新的位置"].contains(value) ? "" : value
    }

    var displayName: String {
        if !displayAlias.isEmpty { return displayAlias }
        return displayTitle.isEmpty ? coordinateText : displayTitle
    }

    var displaySubtitle: String {
        [displayAlias.isEmpty ? "" : displayTitle, displayDetail]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var coordinateText: String {
        String(format: "%.6f, %.6f", latitude, longitude)
    }
}

final class AppWLocFavoriteStore {
    static let shared = AppWLocFavoriteStore()

    // v2 使用独立收藏模型保存别名、原始标题、详细地址和坐标。
    // 按产品要求不读取或迁移 v1，避免旧数据继续混淆“别名”和“地点标题”。
    private let key = "WLocApp.favorites.v2"
    private let defaults: UserDefaults

    init(defaults: UserDefaults? = UserDefaults(suiteName: AppWLocConfig.defaultsSuiteName)) {
        self.defaults = defaults ?? .standard
    }

    func all() -> [AppWLocFavorite] {
        guard let data = defaults.data(forKey: key),
              let places = try? JSONDecoder().decode([AppWLocFavorite].self, from: data) else {
            return []
        }
        return places.sorted { $0.createdAt > $1.createdAt }
    }

    func contains(_ place: AppWLocPlace) -> Bool {
        all().contains { existing in
            abs(existing.latitude - place.latitude) < 0.000001 &&
                abs(existing.longitude - place.longitude) < 0.000001
        }
    }

    func add(_ favorite: AppWLocFavorite) {
        var places = all()
        guard !places.contains(where: {
            abs($0.latitude - favorite.latitude) < 0.000001 &&
                abs($0.longitude - favorite.longitude) < 0.000001
        }) else { return }
        places.insert(favorite, at: 0)
        save(places)
    }

    func remove(id: UUID) {
        save(all().filter { $0.id != id })
    }

    private func save(_ places: [AppWLocFavorite]) {
        guard let data = try? JSONEncoder().encode(places) else { return }
        defaults.set(data, forKey: key)
        defaults.synchronize()
    }
}
