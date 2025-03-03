//
//  RebloggedByViewController.swift
//  Mastodon
//
//  Created by MainasuK on 2022-5-17.
//

import UIKit
import GameplayKit
import Combine
import MastodonCore
import MastodonLocalization
import MastodonUI
import CoreDataStack

final class RebloggedByViewController: UIViewController, NeedsDependency {

    weak var context: AppContext! { willSet { precondition(!isViewLoaded) } }
    weak var coordinator: SceneCoordinator! { willSet { precondition(!isViewLoaded) } }
    
    var disposeBag = Set<AnyCancellable>()
    var viewModel: UserListViewModel!
    
    lazy var tableView: UITableView = {
        let tableView = UITableView()
        tableView.rowHeight = UITableView.automaticDimension
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        return tableView
    }()
}

extension RebloggedByViewController {
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        #if DEBUG
        switch viewModel.kind {
        case .rebloggedBy:  break
        default:            assertionFailure()
        }
        #endif
        
        title = L10n.Scene.RebloggedBy.title
        
        view.backgroundColor = .secondarySystemBackground
        
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        tableView.pinToParent()
        
        tableView.delegate = self
        viewModel.setupDiffableDataSource(
            tableView: tableView,
            userTableViewCellDelegate: self
        )
        
        // setup batch fetch
        viewModel.listBatchFetchViewModel.setup(scrollView: tableView)
        viewModel.listBatchFetchViewModel.shouldFetch
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.viewModel.stateMachine.enter(UserListViewModel.State.Loading.self)
            }
            .store(in: &disposeBag)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        tableView.deselectRow(with: transitionCoordinator, animated: animated)
    }
    
}

// MARK: - AuthContextProvider
extension RebloggedByViewController: AuthContextProvider {
    var authContext: AuthContext { viewModel.authContext }
}

// MARK: - UITableViewDelegate
extension RebloggedByViewController: UITableViewDelegate, AutoGenerateTableViewDelegate {
    // sourcery:inline:RebloggedByViewController.AutoGenerateTableViewDelegate

    // Generated using Sourcery
    // DO NOT EDIT
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        aspectTableView(tableView, didSelectRowAt: indexPath)
    }

    // sourcery:end
}

// MARK: - UserTableViewCellDelegate
extension RebloggedByViewController: UserTableViewCellDelegate {}
