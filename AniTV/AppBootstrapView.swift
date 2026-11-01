//
//  AppBootstrapView.swift
//  AniTV
//
//  Created by Codex on 2026/4/5.
//

import SwiftUI
import Combine
import SQLiteData
import CoreImage.CIFilterBuiltins
import UIKit

@MainActor
final class AppBootstrapModel: ObservableObject {
    enum Phase: Equatable {
        case oobe
        case preparing
        case downloadingBangumiData
        case importingBangumiData
        case downloadingMediaSources
        case importingMediaSources
        case ready
        case failed(String)

        var message: String {
            switch self {
            case .oobe:
                return ""
            case .preparing:
                return "正在准备应用…"
            case .downloadingBangumiData:
                return "正在下载 Bangumi 数据…"
            case .importingBangumiData:
                return "正在写入 Bangumi 数据…"
            case .downloadingMediaSources:
                return "正在下载数据源配置…"
            case .importingMediaSources:
                return "正在写入数据源配置…"
            case .ready:
                return ""
            case .failed(let message):
                return message
            }
        }
    }

    @Published private(set) var phase: Phase = .preparing

    private let database: DatabaseQueue
    private var didStart = false
    private weak var bangumiOAuthManager: BangumiOAuthManager?
    private var bangumiTokenRefreshTask: Task<Void, Never>?
    private var bangumiDataRefreshLoopTask: Task<Void, Never>?
    private var bangumiDataRefreshTask: Task<Void, Never>?
    private var mediaSourceRefreshTask: Task<Void, Never>?

    init(database: DatabaseQueue) {
        self.database = database
    }

    func setBangumiOAuthManager(_ bangumiOAuthManager: BangumiOAuthManager) {
        self.bangumiOAuthManager = bangumiOAuthManager
    }

    func startIfNeeded() async {
        guard !didStart else { return }
        didStart = true
        await bootstrap()
    }

    func retry() async {
        phase = .preparing
        await bootstrap()
    }

    func createGuestProfile() async {
        do {
            _ = try await AniTVDatabase.insertGuestUserProfile(in: database)
            try await AniTVDatabase.setBangumiOAuthRefreshBlocked(false, in: database)
            phase = .preparing
            await bootstrap()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func finishBangumiLogin(session: BangumiAuthenticatedSession) async {
        do {
            _ = try await AniTVDatabase.upsertCurrentUserProfile(
                bgmUserID: session.bgmUserID,
                username: session.username,
                nickname: session.nickname,
                avatar: session.avatar,
                accessToken: session.accessToken,
                refreshToken: session.refreshToken,
                tokenType: session.tokenType,
                expiresAt: session.expiresAt,
                in: database
            )
            try await AniTVDatabase.setBangumiOAuthRedirectURI(session.redirectURI, in: database)
            try await AniTVDatabase.setBangumiOAuthRefreshBlocked(false, in: database)
            if phase == .ready {
                startBangumiDataRefreshLoopIfNeeded()
                await triggerBangumiTokenRefreshIfNeeded()
                await triggerBangumiDataRefreshIfNeeded()
                await triggerMediaSourceRefreshIfNeeded()
            } else {
                phase = .preparing
                await bootstrap()
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func bootstrap() async {
        do {
            if try await AniTVDatabase.isMediaSourceEmpty(in: database) {
                try await performInitialMediaSourceLoad()
            }

            if try await AniTVDatabase.currentUserProfile(in: database) == nil {
                bangumiTokenRefreshTask?.cancel()
                bangumiTokenRefreshTask = nil
                bangumiDataRefreshTask?.cancel()
                bangumiDataRefreshTask = nil
                mediaSourceRefreshTask?.cancel()
                mediaSourceRefreshTask = nil
                bangumiDataRefreshLoopTask?.cancel()
                bangumiDataRefreshLoopTask = nil
                phase = .oobe
                return
            }

            if try await AniTVDatabase.isBangumiDataEmpty(in: database) {
                try await performInitialBangumiDataLoad()
            }

            phase = .ready
            startBangumiDataRefreshLoopIfNeeded()
            Task.detached(priority: .utility) {
                await TmdbSubjectMapManager.shared.ensureLoaded()
            }
            await triggerBangumiTokenRefreshIfNeeded()
            await triggerBangumiDataRefreshIfNeeded()
            await triggerMediaSourceRefreshIfNeeded()
            print("[AppBootstrap] Bootstrap finished")
        } catch {
            AniTVDatabase.logBootstrapError(error)
            print("[AppBootstrap] Bootstrap failed: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    private func performInitialBangumiDataLoad() async throws {
        phase = .preparing

        let release = try await AniTVDatabase.resolveBangumiDataRelease()
        print("[AppBootstrap] Initial bangumi-data load version: \(release.version)")

        phase = .downloadingBangumiData
        let items = try await AniTVDatabase.downloadBangumiData(from: release.url)

        phase = .importingBangumiData
        try await AniTVDatabase.replaceBangumiData(items, version: release.version, in: database)
        print("[AppBootstrap] Initial bangumi-data load finished")
    }

    private func performInitialMediaSourceLoad() async throws {
        phase = .preparing

        let subscriptionURL = MediaSourceConfigLoader.defaultSubscriptionURL.absoluteString
        print("[AppBootstrap] Initial media source load from: \(subscriptionURL)")

        phase = .downloadingMediaSources
        let didUpdate = try await AniTVDatabase.refreshMediaSourcesIfNeeded(in: database)

        phase = .importingMediaSources
        print("[AppBootstrap] Initial media source load finished, updated: \(didUpdate)")
    }

    private func startBangumiDataRefreshLoopIfNeeded() {
        guard bangumiDataRefreshLoopTask == nil else { return }

        bangumiDataRefreshLoopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                } catch {
                    break
                }

                guard let self else { break }
                await self.triggerBangumiTokenRefreshIfNeeded()
                await self.triggerBangumiDataRefreshIfNeeded()
                await self.triggerMediaSourceRefreshIfNeeded()
            }
        }
    }

    private func triggerBangumiTokenRefreshIfNeeded() async {
        guard bangumiTokenRefreshTask == nil,
              let bangumiOAuthManager else { return }

        bangumiTokenRefreshTask = Task { @MainActor [weak self, bangumiOAuthManager] in
            guard let self else { return }

            defer {
                self.bangumiTokenRefreshTask = nil
            }

            await bangumiOAuthManager.refreshAccessTokenIfNeeded(in: self.database)
        }
    }

    private func triggerBangumiDataRefreshIfNeeded() async {
        guard bangumiDataRefreshTask == nil else { return }

        do {
            guard try await AniTVDatabase.shouldRefreshBangumiData(in: database) else { return }
        } catch {
            AniTVDatabase.logBootstrapError(error)
            print("[AppBootstrap] Failed to check bangumi-data refresh status: \(error.localizedDescription)")
            return
        }

        bangumiDataRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }

            defer {
                self.bangumiDataRefreshTask = nil
            }

            do {
                let didUpdate = try await AniTVDatabase.refreshBangumiDataIfNeeded(in: self.database)
                print("[AppBootstrap] Background bangumi-data refresh finished, updated: \(didUpdate)")
            } catch {
                AniTVDatabase.logBootstrapError(error)
                print("[AppBootstrap] Background bangumi-data refresh failed: \(error.localizedDescription)")
            }
        }
    }

    private func triggerMediaSourceRefreshIfNeeded() async {
        guard mediaSourceRefreshTask == nil else { return }

        do {
            guard try await AniTVDatabase.shouldRefreshMediaSources(in: database) else { return }
        } catch {
            AniTVDatabase.logBootstrapError(error)
            print("[AppBootstrap] Failed to check media source refresh status: \(error.localizedDescription)")
            return
        }

        mediaSourceRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }

            defer {
                self.mediaSourceRefreshTask = nil
            }

            do {
                let didUpdate = try await AniTVDatabase.refreshMediaSourcesIfNeeded(in: self.database)
                print("[AppBootstrap] Background media source refresh finished, updated: \(didUpdate)")
            } catch {
                AniTVDatabase.logBootstrapError(error)
                print("[AppBootstrap] Background media source refresh failed: \(error.localizedDescription)")
            }
        }
    }
}

struct AppBootstrapView: View {
    @StateObject private var model: AppBootstrapModel
    @EnvironmentObject private var bangumiOAuthManager: BangumiOAuthManager

    init(database: DatabaseQueue) {
        _model = StateObject(wrappedValue: AppBootstrapModel(database: database))
    }

    var body: some View {
        Group {
            if model.phase == .ready {
                SidebarContentView()
            } else if model.phase == .oobe {
                OOBEProfileSetupView(
                    isAuthenticating: bangumiOAuthManager.isAuthenticating,
                    statusMessage: bangumiOAuthManager.statusMessage,
                    lanEntryURL: bangumiOAuthManager.lanEntryURL,
                    lanServiceStatus: bangumiOAuthManager.lanServiceStatus,
                    createGuestAction: {
                        Task { await model.createGuestProfile() }
                    },
                    connectBangumiAction: {
                        bangumiOAuthManager.startLogin(
                            clientID: BangumiOAuthManager.sharedClientID,
                            clientSecret: BangumiOAuthManager.sharedClientSecret,
                            redirectURI: BangumiOAuthManager.defaultRedirectURI
                        )
                    }
                )
            } else {
                bootstrapProgressView
            }
        }
        .task {
            model.setBangumiOAuthManager(bangumiOAuthManager)
            await model.startIfNeeded()
        }
        .onChange(of: bangumiOAuthManager.authenticatedSession) { _, session in
            guard let session else { return }
            let consumed = bangumiOAuthManager.consumeAuthenticatedSession() ?? session
            Task {
                await model.finishBangumiLogin(session: consumed)
            }
        }
    }

    private var bootstrapProgressView: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black,
                    Color(red: 0.08, green: 0.09, blue: 0.14)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)

                Text(model.phase.message)
                    .font(.headline)
                    .foregroundStyle(.white)

                if case .failed(let message) = model.phase {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.center)

                    Button("重试") {
                        Task {
                            await model.retry()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
            .frame(maxWidth: 560)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            }
            .padding(32)
        }
    }
}
