//
//  APIService+Follow.swift
//  Mastodon
//
//  Created by MainasuK Cirno on 2021-4-2.
//

import UIKit
import Combine
import CoreData
import CoreDataStack
import MastodonSDK

extension APIService {

    private struct MastodonFollowContext {
        let sourceUserID: MastodonUser.ID
        let targetUserID: MastodonUser.ID
        let isFollowing: Bool
        let isPending: Bool
        let needsUnfollow: Bool
    }
    
    /// Toggle friendship between target MastodonUser and current MastodonUser
    ///
    /// Following / Following pending <-> Unfollow
    ///
    /// - Parameters:
    ///   - mastodonUser: target MastodonUser
    ///   - activeMastodonAuthenticationBox: `AuthenticationService.MastodonAuthenticationBox`
    /// - Returns: publisher for `Relationship`
    public func toggleFollow(
        user: ManagedObjectRecord<MastodonUser>,
        authenticationBox: MastodonAuthenticationBox
    ) async throws -> Mastodon.Response.Content<Mastodon.Entity.Relationship> {

        let managedObjectContext = backgroundManagedObjectContext
        let _followContext: MastodonFollowContext? = try await managedObjectContext.performChanges {
            guard let me = authenticationBox.authentication.user(in: managedObjectContext) else { return nil }
            guard let user = user.object(in: managedObjectContext) else { return nil }
            
            let isFollowing = user.followingBy.contains(me)
            let isPending = user.followRequestedBy.contains(me)
            let needsUnfollow = isFollowing || isPending
            
            if needsUnfollow {
                // unfollow
                user.update(isFollowing: false, by: me)
                user.update(isFollowRequested: false, by: me)
            } else {
                // follow
                if user.locked {
                    user.update(isFollowing: false, by: me)
                    user.update(isFollowRequested: true, by: me)
                } else {
                    user.update(isFollowing: true, by: me)
                    user.update(isFollowRequested: false, by: me)
                }
            }
            let context = MastodonFollowContext(
                sourceUserID: me.id,
                targetUserID: user.id,
                isFollowing: isFollowing,
                isPending: isPending,
                needsUnfollow: needsUnfollow
            )
            return context
        }
        
        guard let followContext = _followContext else {
            throw APIError.implicit(.badRequest)
        }
        
        // request follow or unfollow
        let result: Result<Mastodon.Response.Content<Mastodon.Entity.Relationship>, Error>
        do {
            let response = try await Mastodon.API.Account.follow(
                session: session,
                domain: authenticationBox.domain,
                accountID: followContext.targetUserID,
                followQueryType: followContext.needsUnfollow ? .unfollow : .follow(query: .init()),
                authorization: authenticationBox.userAuthorization
            ).singleOutput()
            result = .success(response)
        } catch {
            result = .failure(error)
        }
        
        // update friendship state
        try await managedObjectContext.performChanges {
            guard let me = authenticationBox.authentication.user(in: managedObjectContext),
                  let user = user.object(in: managedObjectContext)
            else { return }
            
            switch result {
            case .success(let response):
                Persistence.MastodonUser.update(
                    mastodonUser: user,
                    context: Persistence.MastodonUser.RelationshipContext(
                        entity: response.value,
                        me: me,
                        networkDate: response.networkDate
                    )
                )
            case .failure:
                // rollback
                user.update(isFollowing: followContext.isFollowing, by: me)
                user.update(isFollowRequested: followContext.isPending, by: me)
            }
        }
        
        let response = try result.get()
        return response
    }

    public func toggleShowReblogs(
      for user: ManagedObjectRecord<MastodonUser>,
      authenticationBox: MastodonAuthenticationBox
    ) async throws -> Mastodon.Response.Content<Mastodon.Entity.Relationship> {

        let managedObjectContext = backgroundManagedObjectContext
        guard let user = user.object(in: managedObjectContext),
              let me = authenticationBox.authentication.user(in: managedObjectContext)
        else { throw APIError.implicit(.badRequest) }

        let result: Result<Mastodon.Response.Content<Mastodon.Entity.Relationship>, Error>

        let oldShowReblogs = me.showingReblogsBy.contains(user)
        let newShowReblogs = (oldShowReblogs == false)

        do {
            let response = try await Mastodon.API.Account.follow(
                session: session,
                domain: authenticationBox.domain,
                accountID: user.id,
                followQueryType: .follow(query: .init(reblogs: newShowReblogs)),
                authorization: authenticationBox.userAuthorization
            ).singleOutput()

            result = .success(response)
        } catch {
            result = .failure(error)
        }

        try await managedObjectContext.performChanges {
            guard let me = authenticationBox.authentication.user(in: managedObjectContext) else { return }

            switch result {
                case .success(let response):
                    Persistence.MastodonUser.update(
                        mastodonUser: user,
                        context: Persistence.MastodonUser.RelationshipContext(
                            entity: response.value,
                            me: me,
                            networkDate: response.networkDate
                        )
                    )
                case .failure:
                    // rollback
                    user.update(isShowingReblogs: oldShowReblogs, by: me)
            }
        }

        return try result.get()
    }
}
