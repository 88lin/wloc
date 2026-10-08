import SnapKit
import UIKit

final class WLocFavoritesViewController: UITableViewController {
    var onSelect: ((AppWLocPlace) -> Void)?
    private var favorites: [AppWLocFavorite] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "收藏地点"
        tableView.register(WLocFavoriteCell.self, forCellReuseIdentifier: "favorite")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 96
        tableView.separatorStyle = .none
        tableView.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 16, right: 0)
        if #available(iOS 13.0, *) { tableView.backgroundColor = .systemBackground }
        reload()
    }

    /// 删除或打开收藏夹时刷新列表，空列表保留简洁提示。
    private func reload() {
        favorites = AppWLocFavoriteStore.shared.all()
        tableView.reloadData()
        if favorites.isEmpty {
            let label = UILabel()
            label.text = "还没有收藏地点"
            label.font = .systemFont(ofSize: 15, weight: .medium)
            label.textColor = .gray
            label.textAlignment = .center
            tableView.backgroundView = label
        } else {
            tableView.backgroundView = nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        favorites.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "favorite", for: indexPath) as! WLocFavoriteCell
        cell.configure(with: favorites[indexPath.row])
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        onSelect?(favorites[indexPath.row].place)
    }

    override func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete else { return }
        AppWLocFavoriteStore.shared.remove(id: favorites[indexPath.row].id)
        reload()
    }
}

private final class WLocFavoriteCell: UITableViewCell {
    private let cardView = UIView()
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private let coordinateLabel = UILabel()
    private var cardColor: UIColor {
        if #available(iOS 13.0, *) { return .secondarySystemBackground }
        return UIColor(white: 0.96, alpha: 1)
    }

    /// 收藏行采用淡色圆角底、星标和分层文字，保留整行点击与滑动删除。
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        cardView.backgroundColor = cardColor
        cardView.layer.cornerRadius = 12
        if #available(iOS 13.0, *) { cardView.layer.cornerCurve = .continuous }
        contentView.addSubview(cardView)
        cardView.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.top.bottom.equalToSuperview().inset(4)
            make.height.greaterThanOrEqualTo(80)
        }

        let iconBackground = UIView()
        iconBackground.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.1)
        iconBackground.layer.cornerRadius = 10
        let iconView = UIImageView(image: WLocExternalIcon.image(
            named: "star.fill", fallback: .symbol("★"), size: CGSize(width: 17, height: 17)
        ).withRenderingMode(.alwaysTemplate))
        iconView.tintColor = .systemBlue
        iconView.contentMode = .scaleAspectFit
        iconBackground.addSubview(iconView)
        cardView.addSubview(iconBackground)
        iconBackground.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(12)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(36)
        }
        iconView.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.width.height.equalTo(18)
        }

        nameLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: 15, weight: .semibold))
        detailLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 12))
        coordinateLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .monospacedDigitSystemFont(ofSize: 11, weight: .regular))
        nameLabel.textColor = .black
        detailLabel.textColor = .gray
        coordinateLabel.textColor = .gray
        if #available(iOS 13.0, *) {
            nameLabel.textColor = .label
            detailLabel.textColor = .secondaryLabel
            coordinateLabel.textColor = .secondaryLabel
        }
        let textStack = UIStackView(arrangedSubviews: [nameLabel, detailLabel, coordinateLabel])
        textStack.axis = .vertical
        textStack.spacing = 4
        [nameLabel, detailLabel, coordinateLabel].forEach { label in
            label.adjustsFontForContentSizeCategory = true
            label.lineBreakMode = .byTruncatingTail
        }
        cardView.addSubview(textStack)
        let chevron = UILabel()
        chevron.text = "›"
        chevron.font = .systemFont(ofSize: 22, weight: .regular)
        chevron.textColor = .lightGray
        cardView.addSubview(chevron)
        chevron.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(12)
            make.centerY.equalToSuperview()
            make.width.equalTo(10)
        }
        textStack.snp.makeConstraints { make in
            make.leading.equalTo(iconBackground.snp.trailing).offset(10)
            make.trailing.equalTo(chevron.snp.leading).offset(-10)
            make.centerY.equalToSuperview()
            make.top.greaterThanOrEqualToSuperview().inset(12)
            make.bottom.lessThanOrEqualToSuperview().inset(12)
        }
    }

    required init?(coder: NSCoder) { nil }

    /// 没有名称或地址时收起对应文字行；仅有坐标时直接将坐标作为主行。
    func configure(with favorite: AppWLocFavorite) {
        nameLabel.text = favorite.displayName
        detailLabel.text = favorite.displaySubtitle
        detailLabel.isHidden = favorite.displaySubtitle.isEmpty
        coordinateLabel.text = favorite.coordinateText
        coordinateLabel.isHidden = favorite.displayAlias.isEmpty && favorite.displayTitle.isEmpty
        accessibilityLabel = [favorite.displayName, favorite.displaySubtitle, coordinateLabel.isHidden ? "" : favorite.coordinateText]
            .filter { !$0.isEmpty }.joined(separator: "，")
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        cardView.backgroundColor = highlighted ? UIColor.systemBlue.withAlphaComponent(0.1) : cardColor
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        cardView.backgroundColor = cardColor
    }
}
