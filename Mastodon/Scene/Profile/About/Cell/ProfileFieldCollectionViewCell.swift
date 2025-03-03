//
//  ProfileFieldCollectionViewCell.swift
//  Mastodon
//
//  Created by MainasuK Cirno on 2021-5-25.
//

import UIKit
import Combine
import MetaTextKit
import MastodonAsset
import MastodonLocalization

protocol ProfileFieldCollectionViewCellDelegate: AnyObject {
    func profileFieldCollectionViewCell(_ cell: ProfileFieldCollectionViewCell, metaLabel: MetaLabel, didSelectMeta meta: Meta)
}

final class ProfileFieldCollectionViewCell: UICollectionViewCell {
    
    var disposeBag = Set<AnyCancellable>()
    
    weak var delegate: ProfileFieldCollectionViewCellDelegate?

    // for custom emoji display
    let keyMetaLabel = MetaLabel(style: .profileFieldName)
    let valueMetaLabel = MetaLabel(style: .profileFieldValue)
    
    let checkmark = UIImageView(image: Asset.Editing.checkmark.image.withRenderingMode(.alwaysTemplate))
    var checkmarkPopoverString: String? = nil;
    let tapGesture = UITapGestureRecognizer();
    var editMenuInteraction: UIEditMenuInteraction!

    override func prepareForReuse() {
        super.prepareForReuse()
        
        disposeBag.removeAll()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        _init()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        _init()
    }
    
}

extension ProfileFieldCollectionViewCell {
    
    private func _init() {

        editMenuInteraction = UIEditMenuInteraction(delegate: self)

        // Setup colors
        checkmark.tintColor = Asset.Scene.Profile.About.bioAboutFieldVerifiedText.color;
        
        // Setup gestures
        tapGesture.addTarget(self, action: #selector(ProfileFieldCollectionViewCell.didTapCheckmark(_:)))
        checkmark.addGestureRecognizer(tapGesture)
        checkmark.isUserInteractionEnabled = true
        checkmark.addInteraction(editMenuInteraction)

        // Setup Accessibility
        checkmark.isAccessibilityElement = true
        checkmark.accessibilityTraits = .none
        keyMetaLabel.accessibilityTraits = .none

        // containerStackView: V - [ metaContainer | plainContainer ]
        let containerStackView = UIStackView()
        containerStackView.axis = .vertical
        
        contentView.preservesSuperviewLayoutMargins = true
        containerStackView.preservesSuperviewLayoutMargins = true
        containerStackView.isLayoutMarginsRelativeArrangement = true
        containerStackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(containerStackView)
        NSLayoutConstraint.activate([
            containerStackView.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            containerStackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerStackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomAnchor.constraint(equalTo: containerStackView.bottomAnchor, constant: 11),
        ])
        
        // metaContainer: V - [ keyMetaLabel | valueContainer ]
        let metaContainer = UIStackView()
        metaContainer.axis = .vertical
        metaContainer.spacing = 2
        containerStackView.addArrangedSubview(metaContainer)
        
        // valueContainer: H - [ valueMetaLabel | checkmark ]
        let valueContainer = UIStackView()
        valueContainer.axis = .horizontal
        valueContainer.spacing = 2
        
        metaContainer.addArrangedSubview(keyMetaLabel)
        valueContainer.addArrangedSubview(valueMetaLabel)
        valueContainer.addArrangedSubview(checkmark)
        metaContainer.addArrangedSubview(valueContainer)
        
        keyMetaLabel.linkDelegate = self
        valueMetaLabel.linkDelegate = self

        isAccessibilityElement = true
    }
    
    @objc public func didTapCheckmark(_ recognizer: UITapGestureRecognizer) {
        editMenuInteraction?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: recognizer.location(in: checkmark)))
    }

    private var valueMetas: [(title: String, Meta)] {
        var result: [(title: String, Meta)] = []
        valueMetaLabel.textStorage.enumerateAttribute(NSAttributedString.Key("MetaAttributeKey.meta"), in: NSMakeRange(0, valueMetaLabel.textStorage.length)) { value, range, _ in
            if let value = value as? Meta {
                result.append((valueMetaLabel.textStorage.string.substring(with: range), value))
            }
        }
        return result
    }

    override func accessibilityActivate() -> Bool {
        if let (_, meta) = valueMetas.first {
            delegate?.profileFieldCollectionViewCell(self, metaLabel: valueMetaLabel, didSelectMeta: meta)
            return true
        }
        return false
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            let valueMetas = valueMetas
            if valueMetas.count < 2 { return nil }
            return valueMetas.compactMap { title, meta in
                guard let name = meta.accessibilityLabel else { return nil }
                return UIAccessibilityCustomAction(name: name) { [weak self] _ in
                    guard let self, let delegate = self.delegate else { return false }
                    delegate.profileFieldCollectionViewCell(self, metaLabel: self.valueMetaLabel, didSelectMeta: meta)
                    return true
                }
            }
        }
        set {}
    }
}

// UIMenuController boilerplate
@available(iOS, deprecated: 16, message: "Can be removed when target version is >=16 -- boilerplate to maintain compatibility with UIMenuController")
extension ProfileFieldCollectionViewCell {
    override var canBecomeFirstResponder: Bool { true }
    
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(dismissVerifiedMenu) {
            return true
        }
        
        return super.canPerformAction(action, withSender: sender)
    }
    
    @objc public func dismissVerifiedMenu() {
        UIMenuController.shared.hideMenu()
    }
}

// MARK: - MetaLabelDelegate
extension ProfileFieldCollectionViewCell: MetaLabelDelegate {
    func metaLabel(_ metaLabel: MetaLabel, didSelectMeta meta: Meta) {
        delegate?.profileFieldCollectionViewCell(self, metaLabel: metaLabel, didSelectMeta: meta)
    }
}

// MARK: UIEditMenuInteractionDelegate
extension ProfileFieldCollectionViewCell: UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let editMenuLabel = checkmarkPopoverString else { return UIMenu(children: []) }
        return UIMenu(children: [UIAction(title: editMenuLabel) { _ in return }])
    }
    
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        return checkmark.frame
    }
}
