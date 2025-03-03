//
//  HomeTimelineViewController.swift
//  Mastodon
//
//  Created by sxiaojian on 2021/2/5.
//

import UIKit
import AVKit
import Combine
import CoreData
import CoreDataStack
import GameplayKit
import MastodonSDK
import AlamofireImage
import StoreKit
import MastodonAsset
import MastodonCore
import MastodonUI
import MastodonLocalization

final class HomeTimelineViewController: UIViewController, NeedsDependency, MediaPreviewableViewController {

    weak var context: AppContext! { willSet { precondition(!isViewLoaded) } }
    weak var coordinator: SceneCoordinator! { willSet { precondition(!isViewLoaded) } }
    
    var disposeBag = Set<AnyCancellable>()
    var viewModel: HomeTimelineViewModel!
    
    let mediaPreviewTransitionController = MediaPreviewTransitionController()

    let friendsAssetImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.image = Asset.Asset.friends.image
        imageView.contentMode = .scaleAspectFill
        return imageView
    }()
    
    lazy var emptyView: UIStackView = {
        let emptyView = UIStackView()
        emptyView.axis = .vertical
        emptyView.distribution = .fill
        emptyView.isLayoutMarginsRelativeArrangement = true
        return emptyView
    }()
    
    let titleView = HomeTimelineNavigationBarTitleView()
    
    let settingBarButtonItem: UIBarButtonItem = {
        let barButtonItem = UIBarButtonItem()
        barButtonItem.tintColor = SystemTheme.tintColor
        barButtonItem.image = Asset.ObjectsAndTools.gear.image.withRenderingMode(.alwaysTemplate)
        barButtonItem.accessibilityLabel = L10n.Common.Controls.Actions.settings
        return barButtonItem
    }()
    
    let tableView: UITableView = {
        let tableView = ControlContainableTableView()
        tableView.register(StatusTableViewCell.self, forCellReuseIdentifier: String(describing: StatusTableViewCell.self))
        tableView.register(TimelineMiddleLoaderTableViewCell.self, forCellReuseIdentifier: String(describing: TimelineMiddleLoaderTableViewCell.self))
        tableView.register(TimelineBottomLoaderTableViewCell.self, forCellReuseIdentifier: String(describing: TimelineBottomLoaderTableViewCell.self))
        tableView.rowHeight = UITableView.automaticDimension
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        return tableView
    }()
    
    let publishProgressView: UIProgressView = {
        let progressView = UIProgressView(progressViewStyle: .bar)
        progressView.alpha = 0
        return progressView
    }()
    
    let refreshControl = RefreshControl()
}

extension HomeTimelineViewController {
    
    override func viewDidLoad() {
        super.viewDidLoad()

        title = L10n.Scene.HomeTimeline.title
        view.backgroundColor = .secondarySystemBackground

        viewModel.$displaySettingBarButtonItem
            .receive(on: DispatchQueue.main)
            .sink { [weak self] displaySettingBarButtonItem in
                guard let self = self else { return }

                self.navigationItem.rightBarButtonItem = displaySettingBarButtonItem ? self.settingBarButtonItem : nil
            }
            .store(in: &disposeBag)

        settingBarButtonItem.target = self
        settingBarButtonItem.action = #selector(HomeTimelineViewController.settingBarButtonItemPressed(_:))
        
        navigationItem.titleView = titleView
        titleView.delegate = self
        
        viewModel.homeTimelineNavigationBarTitleViewModel.state
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                self.titleView.configure(state: state)
            }
            .store(in: &disposeBag)
        
        viewModel.homeTimelineNavigationBarTitleViewModel.state
            .removeDuplicates()
            .filter { $0 == .publishedButton }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                guard UserDefaults.shared.lastVersionPromptedForReview == nil else { return }
                guard UserDefaults.shared.processCompletedCount > 3 else { return }
                guard let windowScene = self.view.window?.windowScene else { return }
                let version = UIApplication.appVersion()
                UserDefaults.shared.lastVersionPromptedForReview = version
                SKStoreReviewController.requestReview(in: windowScene)
            }
            .store(in: &disposeBag)
        
        tableView.refreshControl = refreshControl
        refreshControl.addTarget(self, action: #selector(HomeTimelineViewController.refreshControlValueChanged(_:)), for: .valueChanged)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        tableView.pinToParent()
        
        // // layout publish progress
        publishProgressView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(publishProgressView)
        NSLayoutConstraint.activate([
            publishProgressView.topAnchor.constraint(equalTo: view.layoutMarginsGuide.topAnchor),
            publishProgressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            publishProgressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        viewModel.tableView = tableView
        tableView.delegate = self
        viewModel.setupDiffableDataSource(
            tableView: tableView,
            statusTableViewCellDelegate: self,
            timelineMiddleLoaderTableViewCellDelegate: self
        )
        
        // setup batch fetch
        viewModel.listBatchFetchViewModel.setup(scrollView: tableView)
        viewModel.listBatchFetchViewModel.shouldFetch
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                guard self.view.window != nil else { return }
                self.viewModel.loadOldestStateMachine.enter(HomeTimelineViewModel.LoadOldestState.Loading.self)
            }
            .store(in: &disposeBag)
        
        // bind refresh control
        viewModel.didLoadLatest
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                UIView.animate(withDuration: 0.5) { [weak self] in
                    guard let self = self else { return }
                    self.refreshControl.endRefreshing()
                } completion: { _ in }
            }
            .store(in: &disposeBag)
        
        context.publisherService.statusPublishResult.sink { result in
            if case .success(.edit) = result {
                self.viewModel.hasPendingStatusEditReload = true
            }
        }.store(in: &disposeBag)
        
        context.publisherService.$currentPublishProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                guard let self = self else { return }
                let progress = Float(progress)

                guard progress > 0 else {
                    let dismissAnimator = UIViewPropertyAnimator(duration: 0.1, curve: .easeInOut)
                    dismissAnimator.addAnimations {
                        self.publishProgressView.alpha = 0
                    }
                    dismissAnimator.addCompletion { _ in
                        self.publishProgressView.setProgress(0, animated: false)
                    }
                    dismissAnimator.startAnimation()
                    return
                }
                if self.publishProgressView.alpha == 0 {
                    let progressAnimator = UIViewPropertyAnimator(duration: 0.1, curve: .easeOut)
                    progressAnimator.addAnimations {
                        self.publishProgressView.alpha = 1
                    }
                    progressAnimator.startAnimation()
                }
                
                self.publishProgressView.setProgress(progress, animated: true)
            }
            .store(in: &disposeBag)
        
        viewModel.timelineIsEmpty
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEmpty in
                if isEmpty {
                    self?.showEmptyView()

                    let userDoesntFollowPeople: Bool
                    if let managedObjectContext = self?.context.managedObjectContext,
                       let authContext = self?.authContext,
                       let me = authContext.mastodonAuthenticationBox.authentication.user(in: managedObjectContext){
                        userDoesntFollowPeople = me.followersCount == 0
                    } else {
                        userDoesntFollowPeople = true
                    }

                    if (self?.viewModel.presentedSuggestions == false) && userDoesntFollowPeople {
                        self?.findPeopleButtonPressed(self)
                        self?.viewModel.presentedSuggestions = true
                    }
                } else {
                    self?.emptyView.removeFromSuperview()
                }
            }
            .store(in: &disposeBag)
        
        NotificationCenter.default
            .publisher(for: .statusBarTapped, object: nil)
            .throttle(for: 0.5, scheduler: DispatchQueue.main, latest: false)
            .sink { [weak self] notification in
                guard let self = self else { return }
                guard let _ = self.view.window else { return } // displaying
                
                // https://developer.limneos.net/index.php?ios=13.1.3&framework=UIKitCore.framework&header=UIStatusBarTapAction.h
                guard let action = notification.object as AnyObject?,
                    let xPosition = action.value(forKey: "xPosition") as? Double
                else { return }
                
                let viewFrameInWindow = self.view.convert(self.view.frame, to: nil)
                guard xPosition >= viewFrameInWindow.minX && xPosition <= viewFrameInWindow.maxX else { return }

                // check if scroll to top
                guard self.shouldRestoreScrollPosition() else { return }
                self.restorePositionWhenScrollToTop()
            }
            .store(in: &disposeBag)

    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        refreshControl.endRefreshing()
        tableView.deselectRow(with: transitionCoordinator, animated: animated)
        
        // needs trigger manually after onboarding dismiss
        setNeedsStatusBarAppearanceUpdate()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        if let timestamp = viewModel.lastAutomaticFetchTimestamp {
            let now = Date()
            if now.timeIntervalSince(timestamp) > 60 {
                self.viewModel.lastAutomaticFetchTimestamp = now
                self.viewModel.homeTimelineNeedRefresh.send()
            } else {
                // do nothing
            }
        } else {
            self.viewModel.homeTimelineNeedRefresh.send()
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        coordinator.animate { _ in
            // do nothing
        } completion: { _ in
            // fix AutoLayout cell height not update after rotate issue
            self.viewModel.cellFrameCache.removeAllObjects()
            self.tableView.reloadData()
        }
    }
}

extension HomeTimelineViewController {
    func showEmptyView() {
        if emptyView.superview != nil {
            return
        }
        view.addSubview(emptyView)
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyView.topAnchor.constraint(equalTo: view.layoutMarginsGuide.topAnchor),
            emptyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyView.bottomAnchor.constraint(equalTo: view.layoutMarginsGuide.bottomAnchor)
        ])
        
        if emptyView.arrangedSubviews.count > 0 {
            return
        }
        let findPeopleButton: PrimaryActionButton = {
            let button = PrimaryActionButton()
            button.setTitle(L10n.Common.Controls.Actions.findPeople, for: .normal)
            button.addTarget(self, action: #selector(HomeTimelineViewController.findPeopleButtonPressed(_:)), for: .touchUpInside)
            return button
        }()
        NSLayoutConstraint.activate([
            findPeopleButton.heightAnchor.constraint(equalToConstant: 46)
        ])
        
        let manuallySearchButton: HighlightDimmableButton = {
            let button = HighlightDimmableButton()
            button.titleLabel?.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: 15, weight: .semibold))
            button.setTitle(L10n.Common.Controls.Actions.manuallySearch, for: .normal)
            button.setTitleColor(Asset.Colors.Brand.blurple.color, for: .normal)
            button.addTarget(self, action: #selector(HomeTimelineViewController.manuallySearchButtonPressed(_:)), for: .touchUpInside)
            return button
        }()

        let topPaddingView = UIView()
        let bottomPaddingView = UIView()

        emptyView.addArrangedSubview(topPaddingView)
        emptyView.addArrangedSubview(friendsAssetImageView)
        emptyView.addArrangedSubview(bottomPaddingView)

        topPaddingView.translatesAutoresizingMaskIntoConstraints = false
        bottomPaddingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topPaddingView.heightAnchor.constraint(equalTo: bottomPaddingView.heightAnchor, multiplier: 0.8),
            manuallySearchButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
        ])

        let buttonContainerStackView = UIStackView()
        emptyView.addArrangedSubview(buttonContainerStackView)
        buttonContainerStackView.isLayoutMarginsRelativeArrangement = true
        buttonContainerStackView.layoutMargins = UIEdgeInsets(top: 0, left: 32, bottom: 22, right: 32)
        buttonContainerStackView.axis = .vertical
        buttonContainerStackView.spacing = 17

        buttonContainerStackView.addArrangedSubview(findPeopleButton)
        buttonContainerStackView.addArrangedSubview(manuallySearchButton)
    }
}

//MARK: - Actions
extension HomeTimelineViewController {
    
    @objc private func findPeopleButtonPressed(_ sender: Any?) {
        let suggestionAccountViewModel = SuggestionAccountViewModel(context: context, authContext: viewModel.authContext)
        suggestionAccountViewModel.delegate = viewModel
        _ = coordinator.present(
            scene: .suggestionAccount(viewModel: suggestionAccountViewModel),
            from: self,
            transition: .modal(animated: true, completion: nil)
        )
    }
    
    @objc private func manuallySearchButtonPressed(_ sender: UIButton) {
        let searchDetailViewModel = SearchDetailViewModel(authContext: viewModel.authContext)
        _ = coordinator.present(scene: .searchDetail(viewModel: searchDetailViewModel), from: self, transition: .modal(animated: true, completion: nil))
    }
    
    @objc private func settingBarButtonItemPressed(_ sender: UIBarButtonItem) {
        guard let setting = context.settingService.currentSetting.value else { return }

        _ = coordinator.present(scene: .settings(setting: setting), from: self, transition: .none)
    }

    @objc private func refreshControlValueChanged(_ sender: RefreshControl) {
        guard viewModel.loadLatestStateMachine.enter(HomeTimelineViewModel.LoadLatestState.LoadingManually.self) else {
            sender.endRefreshing()
            return
        }
    }
    
    @objc func signOutAction(_ sender: UIAction) {
        Task { @MainActor in
            try await context.authenticationService.signOutMastodonUser(authenticationBox: viewModel.authContext.mastodonAuthenticationBox)
            self.coordinator.setup()
        }
    }

}
// MARK: - UIScrollViewDelegate
extension HomeTimelineViewController {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        switch scrollView {
        case tableView:
            viewModel.homeTimelineNavigationBarTitleViewModel.handleScrollViewDidScroll(scrollView)
        default:
            break
        }
    }
    
    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        switch scrollView {
        case tableView:
            
            let indexPath = IndexPath(row: 0, section: 0)
            guard viewModel.diffableDataSource?.itemIdentifier(for: indexPath) != nil else {
                return true
            }
            // save position
            savePositionBeforeScrollToTop()
            // override by custom scrollToRow
            tableView.scrollToRow(at: indexPath, at: .top, animated: true)
            return false
        default:
            assertionFailure()
            return true
        }
    }
    
    private func savePositionBeforeScrollToTop() {
        // check save action interval
        // should not fast than 0.5s to prevent save when scrollToTop on-flying
        if let record = viewModel.scrollPositionRecord {
            let now = Date()
            guard now.timeIntervalSince(record.timestamp) > 0.5 else {
                // skip this save action
                return
            }
        }
        
        guard let diffableDataSource = viewModel.diffableDataSource else { return }
        guard let anchorIndexPaths = tableView.indexPathsForVisibleRows?.sorted() else { return }
        guard !anchorIndexPaths.isEmpty else { return }
        let anchorIndexPath = anchorIndexPaths[anchorIndexPaths.count / 2]
        guard let anchorItem = diffableDataSource.itemIdentifier(for: anchorIndexPath) else { return }
        
        let offset: CGFloat = {
            guard let anchorCell = tableView.cellForRow(at: anchorIndexPath) else { return 0 }
            let cellFrameInView = tableView.convert(anchorCell.frame, to: view)
            return cellFrameInView.origin.y
        }()
        viewModel.scrollPositionRecord = HomeTimelineViewModel.ScrollPositionRecord(
            item: anchorItem,
            offset: offset,
            timestamp: Date()
        )
    }
    
    private func shouldRestoreScrollPosition() -> Bool {
        // check if scroll to top
        guard self.tableView.safeAreaInsets.top > 0 else { return false }
        let zeroOffset = -self.tableView.safeAreaInsets.top
        return abs(self.tableView.contentOffset.y - zeroOffset) < 2.0
    }
    
    private func restorePositionWhenScrollToTop() {
        guard let diffableDataSource = self.viewModel.diffableDataSource else { return }
        guard let record = self.viewModel.scrollPositionRecord,
              let indexPath = diffableDataSource.indexPath(for: record.item)
        else { return }
        
        tableView.scrollToRow(at: indexPath, at: .middle, animated: true)
        viewModel.scrollPositionRecord = nil
    }
}

// MARK: - AuthContextProvider
extension HomeTimelineViewController: AuthContextProvider {
    var authContext: AuthContext { viewModel.authContext }
}

// MARK: - UITableViewDelegate
extension HomeTimelineViewController: UITableViewDelegate, AutoGenerateTableViewDelegate {
    // sourcery:inline:HomeTimelineViewController.AutoGenerateTableViewDelegate

    // Generated using Sourcery
    // DO NOT EDIT
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        aspectTableView(tableView, didSelectRowAt: indexPath)
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        return aspectTableView(tableView, contextMenuConfigurationForRowAt: indexPath, point: point)
    }

    func tableView(_ tableView: UITableView, previewForHighlightingContextMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        return aspectTableView(tableView, previewForHighlightingContextMenuWithConfiguration: configuration)
    }

    func tableView(_ tableView: UITableView, previewForDismissingContextMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        return aspectTableView(tableView, previewForDismissingContextMenuWithConfiguration: configuration)
    }

    func tableView(_ tableView: UITableView, willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionCommitAnimating) {
        aspectTableView(tableView, willPerformPreviewActionForMenuWith: configuration, animator: animator)
    }

    // sourcery:end
    
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if indexPath.row == tableView.numberOfRows(inSection: indexPath.section) - 1 {
            viewModel.timelineDidReachEnd()
        }
    }
}

// MARK: - TimelineMiddleLoaderTableViewCellDelegate
extension HomeTimelineViewController: TimelineMiddleLoaderTableViewCellDelegate {
    func timelineMiddleLoaderTableViewCell(_ cell: TimelineMiddleLoaderTableViewCell, loadMoreButtonDidPressed button: UIButton) {
        guard let diffableDataSource = viewModel.diffableDataSource else { return }
        guard let indexPath = tableView.indexPath(for: cell) else { return }
        guard let item = diffableDataSource.itemIdentifier(for: indexPath) else { return }

        Task {
            await viewModel.loadMore(item: item)
        }
    }
}

// MARK: - ScrollViewContainer
extension HomeTimelineViewController: ScrollViewContainer {
    
    var scrollView: UIScrollView { return tableView }
    
    func scrollToTop(animated: Bool) {
        if scrollView.contentOffset.y < scrollView.frame.height,
           viewModel.loadLatestStateMachine.canEnterState(HomeTimelineViewModel.LoadLatestState.Loading.self),
           (scrollView.contentOffset.y + scrollView.adjustedContentInset.top) == 0.0,
           !refreshControl.isRefreshing {
            scrollView.scrollRectToVisible(CGRect(origin: CGPoint(x: 0, y: -refreshControl.frame.height), size: CGSize(width: 1, height: 1)), animated: animated)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.refreshControl.beginRefreshing()
                self.refreshControl.sendActions(for: .valueChanged)
            }
        } else {
            let indexPath = IndexPath(row: 0, section: 0)
            guard viewModel.diffableDataSource?.itemIdentifier(for: indexPath) != nil else { return }
            // save position
            savePositionBeforeScrollToTop()
            tableView.scrollToRow(at: indexPath, at: .top, animated: true)
        }
    }
    
}

// MARK: - StatusTableViewCellDelegate
extension HomeTimelineViewController: StatusTableViewCellDelegate { }

// MARK: - HomeTimelineNavigationBarTitleViewDelegate
extension HomeTimelineViewController: HomeTimelineNavigationBarTitleViewDelegate {
    func homeTimelineNavigationBarTitleView(_ titleView: HomeTimelineNavigationBarTitleView, logoButtonDidPressed sender: UIButton) {
        if shouldRestoreScrollPosition() {
            restorePositionWhenScrollToTop()
        } else {
            savePositionBeforeScrollToTop()
            scrollToTop(animated: true)
        }
    }
    
    func homeTimelineNavigationBarTitleView(_ titleView: HomeTimelineNavigationBarTitleView, buttonDidPressed sender: UIButton) {
        switch titleView.state {
        case .newPostButton:
            guard let diffableDataSource = viewModel.diffableDataSource else { return }
            let indexPath = IndexPath(row: 0, section: 0)
            guard diffableDataSource.itemIdentifier(for: indexPath) != nil else { return }
        
            savePositionBeforeScrollToTop()
            tableView.scrollToRow(at: indexPath, at: .top, animated: true)
        case .offlineButton:
            // TODO: retry
            break
        case .publishedButton:
            break
        default:
            break
        }
    }
}

extension HomeTimelineViewController {
    override var keyCommands: [UIKeyCommand]? {
        return navigationKeyCommands + statusNavigationKeyCommands
    }
}

// MARK: - StatusTableViewControllerNavigateable
extension HomeTimelineViewController: StatusTableViewControllerNavigateable {
    @objc func navigateKeyCommandHandlerRelay(_ sender: UIKeyCommand) {
        navigateKeyCommandHandler(sender)
    }

    @objc func statusKeyCommandHandlerRelay(_ sender: UIKeyCommand) {
        statusKeyCommandHandler(sender)
    }
}
