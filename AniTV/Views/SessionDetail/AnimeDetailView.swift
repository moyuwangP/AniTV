//
//  AnimeDetailView.swift
//  AniTV
//
//  Created by Feiran Yang on 2026/2/13.
//


import SwiftUI
import Kingfisher
import SQLiteData

struct AnimeDetailView: View {
    let bgmId: Int
    let openEpisodePlayer: ([BgmEpisodeInfo], BgmEpisodeInfo, String, Int?) -> Void
    let playerDismissRefreshToken: Int
    @Dependency(\.defaultDatabase) private var database
    @State private var showingFullInfo = false
    @State private var subject: SubjectDetailDTO?
    @State private var backdropURL: URL?
    @State private var episodeStills: [Int: URL] = [:]
    @State private var episodes: [BgmEpisodeInfo] = []
    @State private var isEpisodesLoading = true
    @State private var mapEntry: TmdbSubjectMapEntry?
    @State private var currentProfile: UserProfile?
    @State private var userEpisodeCollectionTypesByEpisodeID: [Int: Int] = [:]
    @State private var localResumeSecondsByEpisodeID: [Int: Int] = [:]
    @State private var subjectCollectionType: Int?
    @State private var didLoadSubjectCollectionState = false
    @State private var pendingResumePromptEpisode: BgmEpisodeInfo?
    @State private var pendingResumePromptSeconds = 0
    @State private var detailRefreshToken = 1
    @State private var shouldPromptMarkWatchingAfterPlayerExit = false
    @State private var showingMarkWatchingPrompt = false

    private var isBackdropTMDB: Bool {
        backdropURL?.host?.contains("tmdb.org") == true
    }

    init(
        bgmId: Int,
        playerDismissRefreshToken: Int = 0,
        openEpisodePlayer: @escaping ([BgmEpisodeInfo], BgmEpisodeInfo, String, Int?) -> Void = { _, _, _, _ in }
    ) {
        self.bgmId = bgmId
        self.playerDismissRefreshToken = playerDismissRefreshToken
        self.openEpisodePlayer = openEpisodePlayer
    }
    
    var body: some View {
        ZStack {
            //Layer 1: 沉浸式背景图
            GeometryReader { proxy in
                KFImage(backdropURL)
                    .setProcessor(isBackdropTMDB ? DefaultImageProcessor.default : BGMBackdropCropProcessor.default)
                    .resizable()
                    .placeholder {
                        Color.gray.opacity(0.3)
                    }
                    .aspectRatio(contentMode: .fill)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .overlay(
                        // 渐变遮罩：从下往上变黑，保证文字清晰
                        LinearGradient(
                            gradient: Gradient(colors: [
                                .black.opacity(0.95),
                                .black.opacity(0.6),
                                .clear
                            ]),
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    
                
            }
            .edgesIgnoringSafeArea(.all) // 铺满全屏
            
            // Layer 2: 内容区域
            VStack(alignment: .leading, spacing: 40) {
                Spacer() // 把内容推到底部
                
                // A. 顶部元信息区 (标题 + 简介)
                HStack(alignment: .bottom, spacing: 60) {
                    VStack(alignment: .leading, spacing: 20) {
                        // 1. 标题 (优先展示 Logo，回退展示文字)
                        Group {
                            switch titleDisplayMode {
                            case .chineseLogo(let url, let aspect), .originalLogo(let url, let aspect):
                                KFImage(url)
                                    .resizable()
                                    .placeholder {
                                        Text(displayName)
                                            .font(.system(size: 60, weight: .heavy, design: .rounded))
                                            .shadow(radius: 10)
                                    }
                                    .aspectRatio(aspect, contentMode: .fit)
                                    .frame(maxHeight: 120, alignment: .leading)
                                    .shadow(color: .black.opacity(0.8), radius: 10, x: 0, y: 5)
                            case .text(let title):
                                Text(title)
                                    .font(.system(size: 60, weight: .heavy, design: .rounded))
                                    .shadow(radius: 10)
                            }
                        }
                        
                        // 2. 标签行 (年份 | 评分 | 类型)
                        HStack(spacing: 20) {
                            if let starts = startDate {
                                var dateString: String {
                                    let formatter = DateFormatter()
                                    formatter.dateFormat = "yyyy年M月"
                                    return formatter.string(from: starts)
                                }
                                BadgeView(text: dateString)
                            }
                            BadgeView(text: typeText.uppercased())
                            if !secondaryTitleText.isEmpty {
                                Text(secondaryTitleText)
                            }
                        }
                        
                        ScoreView(
                            score: score,
                            count: count,
                            rank: rank
                        )
                        // 给评分和下方的标签加点间距
                        .padding(.bottom, 10)
                        
                        // 3. 简介 (限制行数，白字，focus后黑字白底)
                        Button(action: { self.showingFullInfo = true }) {
                            Text(infoText)
                                .font(.body)
                                .foregroundColor(isDescriptionFocused ? .black : .white)
                                .lineLimit(3)
                                .frame(maxWidth: 900, alignment: .leading)
                                .padding(.horizontal, isDescriptionFocused ? 14 : 0)
                                .padding(.vertical, isDescriptionFocused ? 8 : 0)
                                .background(
                                    isDescriptionFocused ? Color.white : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                        .focused($focusedField, equals: "description")
                        .animation(.easeInOut(duration: 0.18), value: isDescriptionFocused)
                        
                        // 4. 操作按钮组
                        HStack(spacing: 20) {
                            Button(action: handlePlayButtonTap) {
                                Label(playButtonTitle, systemImage: "play.fill")
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                            }
                            // 2. 修正这里：参数是 (true, in: namespace)
                            .prefersDefaultFocus(true, in: focusNamespace)
                            .focused($focusedField, equals: "playButton")
                            
                            Menu {
                                ForEach(subjectCollectionMenuOptions, id: \.rawValue) { option in
                                    Button {
                                        handleSubjectCollectionMenuSelection(option)
                                    } label: {
                                        Label(option.title, systemImage: option.systemImage)
                                    }
                                }
                            } label: {
                                Label(subjectCollectionButtonTitle, systemImage: subjectCollectionButtonSystemImage)
                            }
                        }
                    }.focusScope(focusNamespace)
                }
//                .padding(.horizontal, 80) // tvOS 两侧留白通常较大
                
                // B. 底部剧集列表 (Shelf)
                VStack(alignment: .leading, spacing: 6) {
                    Text("剧集列表")
                        .font(.title3)
                        .fontWeight(.bold)
                        .offset(y: isShelfTitleLifted ? -16 : 0)
                        .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.82), value: isShelfTitleLifted)
//                        .padding(.horizontal, 80)

                    ScrollViewReader { scrollProxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 40) {
                                if isEpisodesLoading && episodes.isEmpty {
                                    ForEach(0..<6, id: \.self) { _ in
                                        EpisodeSkeletonCardView()
                                    }
                                } else {
                                    ForEach(episodes, id: \.id) { episode in
                                        EpisodeCardView(
                                            episodeInfo: episode,
                                            sessionTitle: displayName,
                                            stillURL: episodeStills[episode.id],
                                            isWatched: effectiveIsWatched(for: episode),
                                            onOpenPlayer: {
                                                handleEpisodeCardTap(episode)
                                            },
                                            onToggleWatched: {
                                                handleEpisodeWatchToggle(episode)
                                            }
                                        )
                                        .id(episode.id)
                                        .focused($focusedEpisodeID, equals: episode.id)
                                    }
                                }
                            }
                            .padding(.top, 22)
                            .padding(.bottom, 50)
                            .scrollTargetLayout()
                        }
                        .scrollPosition(id: $scrolledEpisodeID)
                        .frame(height: 320)
                        .onChange(of: scrolledEpisodeID) { _, newScrolledID in
                            guard let newScrolledID else { return }
                            manualLeadingEpisodeID = newScrolledID
                            updateTitleLiftState(for: focusedEpisodeID)
                        }
                        .onChange(of: focusedEpisodeID) { _, newID in
                            updateTitleLiftState(for: newID)
                        }
                        .onChange(of: firstUnwatchedEpisode?.id) { _, episodeID in
                            guard let episodeID else { return }
                            withAnimation(.easeInOut(duration: 0.25)) {
                                scrollProxy.scrollTo(episodeID, anchor: .leading)
                            }
                        }
                        .onAppear {
                            guard let episodeID = firstUnwatchedEpisode?.id else { return }
                            DispatchQueue.main.async {
                                scrollProxy.scrollTo(episodeID, anchor: .leading)
                            }
                        }
                    }
                }
                .focusSection()
            }
        }
        .onAppear {
            focusedField = "playButton"
        }
        .onChange(of: focusedField) { _, newField in
            if newField != nil {
                // 焦点真正离开了剧集列表（例如移动到了“开始播放”或“简介”），落下标题
                if isShelfTitleLifted {
                    isShelfTitleLifted = false
                }
            }
        }
        .onChange(of: playerDismissRefreshToken) { _, refreshToken in
            guard refreshToken > 0 else { return }
            shouldPromptMarkWatchingAfterPlayerExit = true
            detailRefreshToken += 1
        }
        .task(id: detailRefreshToken) {
            await loadData()
        }
        .sheet(isPresented: $showingFullInfo) {
            VStack(spacing: 30) {
                Text("简介")
                    .font(.title.bold())
                
                ScrollView {
                    Text(infoText)
                        .font(.body)
                }
                
                Button("关闭") {
                    self.showingFullInfo = false
                }
            }
            .padding(60)
        }
        .confirmationDialog(
            "检测到本地播放记录",
            isPresented: Binding(
                get: { pendingResumePromptEpisode != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingResumePromptEpisode = nil
                        pendingResumePromptSeconds = 0
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("续播") {
                guard let episode = pendingResumePromptEpisode else { return }
                openEpisodePlayer(episodes, episode, displayName, pendingResumePromptSeconds)
                pendingResumePromptEpisode = nil
                pendingResumePromptSeconds = 0
            }

            Button("从头开始") {
                guard let episode = pendingResumePromptEpisode else { return }
                openEpisodePlayer(episodes, episode, displayName, nil)
                pendingResumePromptEpisode = nil
                pendingResumePromptSeconds = 0
            }

            Button("取消", role: .cancel) {
                pendingResumePromptEpisode = nil
                pendingResumePromptSeconds = 0
            }
        } message: {
            if let episode = pendingResumePromptEpisode {
                Text("第 \(formattedEpisodeNumber(for: episode)) 集存在本地播放记录，是否继续播放？")
            }
        }
        .confirmationDialog(
            "是否标记为在看",
            isPresented: $showingMarkWatchingPrompt,
            titleVisibility: .visible
        ) {
            Button("标记为在看") {
                Task {
                    await markSubjectAsWatchingIfNeeded()
                }
            }

            Button("暂不", role: .cancel) {
                shouldPromptMarkWatchingAfterPlayerExit = false
            }
        } message: {
            Text("当前条目还没有收藏状态，是否将其标记为在看？")
        }
    }
    
    // 用于管理焦点的命名空间
    @FocusState private var focusedField: String?
    @FocusState private var focusedEpisodeID: Int?
    @Namespace var focusNamespace

    @State private var scrolledEpisodeID: Int?
    @State private var manualLeadingEpisodeID: Int?
    @State private var isShelfTitleLifted: Bool = false

    /// 当前停留在视口最左侧（文案正下方）的集数 ID
    private var effectiveLeadingEpisodeID: Int? {
        manualLeadingEpisodeID ?? scrolledEpisodeID ?? firstUnwatchedEpisode?.id ?? episodes.first?.id
    }

    /// 同步更新抬高状态，杜绝任何异步滚动动画导致的脱节或延迟弹跳
    private func updateTitleLiftState(for episodeID: Int?) {
        guard let episodeID else {
            // 焦点是 nil（例如卡片间切换时的过渡瞬态），保持当前高度，绝不误降！
            return
        }

        guard let newIndex = episodes.firstIndex(where: { $0.id == episodeID }) else {
            return
        }

        let leadingID = effectiveLeadingEpisodeID
        let leadingIndex = episodes.firstIndex(where: { $0.id == leadingID }) ?? 0

        if newIndex <= leadingIndex {
            // 焦点移动到当前首张卡片，或往左翻超越了原首张卡片：
            // 同步将该卡片确立为新的 leading 卡片，状态同步升起/保持升起，0ms 延迟，杜绝脱节！
            manualLeadingEpisodeID = episodeID
            if !isShelfTitleLifted {
                isShelfTitleLifted = true
            }
        } else {
            // 焦点在首张卡片右侧（非正下方），标题平滑落下
            if isShelfTitleLifted {
                isShelfTitleLifted = false
            }
        }
    }

    private var isDescriptionFocused: Bool {
        focusedField == "description"
    }

    private enum TitleDisplayMode: Equatable {
        case chineseLogo(url: URL, aspectRatio: Double)
        case originalLogo(url: URL, aspectRatio: Double)
        case text(String)
    }

    private var titleDisplayMode: TitleDisplayMode {
        if let logos = mapEntry?.logos {
            // 优先级 1: 中文 logo
            if let zh = logos.logos["zh"],
               let url = URL(string: "https://image.tmdb.org/t/p/w500" + zh.filePath) {
                return .chineseLogo(url: url, aspectRatio: zh.aspectRatio)
            }
            // 优先级 2: 原始语言 logo
            let origLang = logos.originalLanguage ?? "ja"
            if let orig = logos.logos[origLang],
               let url = URL(string: "https://image.tmdb.org/t/p/w500" + orig.filePath) {
                return .originalLogo(url: url, aspectRatio: orig.aspectRatio)
            }
        }
        // 优先级 3: 纯文字标题
        return .text(displayName)
    }

    private var secondaryTitleText: String {
        switch titleDisplayMode {
        case .originalLogo:
            // 在展示原始语言logo时展示中文标题
            return displayName
        case .chineseLogo, .text:
            return originalTitle
        }
    }

    private var displayName: String {
        if let nameCN = subject?.nameCN, !nameCN.isEmpty { return nameCN }
        return subject?.name ?? "加载中..."
    }

    private var originalTitle: String {
        subject?.name ?? ""
    }

    private var infoText: String {
        if let summary = subject?.summary, !summary.isEmpty { return summary }
        if let info = subject?.info, !info.isEmpty { return info }
        return "暂无简介"
    }

    private var typeText: String {
        guard let type = subject?.type else { return "UNKNOWN" }
        switch type {
        case 2: return "TV"
        case 6: return "LIVE"
        default: return "TYPE\(type)"
        }
    }

    private var score: Double {
        subject?.rating.score ?? 0
    }

    private var count: Int {
        subject?.rating.total ?? 0
    }

    private var rank: Int {
        subject?.rating.rank ?? 0
    }

    private var startDate: Date? {
        guard let dateString = subject?.date, !dateString.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: dateString)
    }

    private var watchedEpisodeIDs: Set<Int> {
        Set(
            userEpisodeCollectionTypesByEpisodeID.compactMap { episodeID, type in
                type == 2 ? episodeID : nil
            }
        )
    }

    private var hasWatchedRecord: Bool {
        episodes.contains(where: effectiveIsWatched(for:))
    }

    private var allEpisodesWatched: Bool {
        !episodes.isEmpty && episodes.allSatisfy(effectiveIsWatched(for:))
    }

    private var firstUnwatchedEpisode: BgmEpisodeInfo? {
        if hasWatchedRecord,
           let first = episodes.first(where: { !effectiveIsWatched(for: $0) }) {
            return first
        }
        return episodes.first
    }

    private var playButtonTitle: String {
        guard hasWatchedRecord, !allEpisodesWatched, let episode = firstUnwatchedEpisode else {
            return "开始播放"
        }
        return "继续播放第\(formattedEpisodeNumber(for: episode))集"
    }

    private var subjectCollectionButtonTitle: String {
        guard let collectionType = subjectCollectionType,
              let subjectCollectionType = SubjectCollectionType(rawValue: collectionType) else {
            return "追番"
        }

        switch subjectCollectionType {
        case .wish:
            return "想看"
        case .collected:
            return "看过"
        case .watching:
            return "在看"
        case .onHold:
            return "搁置"
        case .dropped:
            return "抛弃"
        }
    }

    private var subjectCollectionButtonSystemImage: String {
        guard let collectionType = subjectCollectionType,
              let subjectCollectionType = SubjectCollectionType(rawValue: collectionType) else {
            return "star"
        }

        switch subjectCollectionType {
        case .wish:
            return "calendar.badge.plus"
        case .collected:
            return "checkmark.circle"
        case .watching:
            return "livephoto.play"
        case .onHold:
            return "clock.badge.questionmark"
        case .dropped:
            return "slash.circle"
        }
    }

    private var subjectCollectionMenuOptions: [SubjectCollectionType] {
        [.wish, .watching, .collected, .onHold, .dropped]
    }

    private func loadData() async {
        let bgmRepo = BangumiRepository()
        var authenticatedProfile: UserProfile?
        await MainActor.run {
            didLoadSubjectCollectionState = false
        }
        do {
            let profile = try await AniTVDatabase.currentUserProfile(in: database)
            authenticatedProfile = profile
            await MainActor.run {
                currentProfile = profile
            }
        } catch {
            print("Failed to load current profile: \(error)")
        }

        do {
            let detail = try await bgmRepo.getSubject(subjectID: bgmId)
            await MainActor.run {
                subject = detail
                // Fallback: use Bangumi large image first.
                if let large = detail.images?.large {
                    backdropURL = URL(string: large)
                }
            }

            let tmdbRepo = TMDBRepository()
            let backdrop = await tmdbRepo.getBackdrop(subjectId: bgmId)
            let entry = await TmdbSubjectMapManager.shared.lookup(subjectId: bgmId)
            await MainActor.run {
                self.mapEntry = entry
                // Prefer TMDB backdrop; keep BGM image when TMDB fails.
                if !backdrop.isEmpty {
                    backdropURL = URL(string: backdrop)
                }
            }
        } catch {
            print("Failed to load subject detail: \(error)")
        }

        isEpisodesLoading = true
        do {
            let response = try await bgmRepo.getEpisodes(id: bgmId)
            await MainActor.run {
                episodes = response.data
                isEpisodesLoading = false
            }
            // 异步并发拉取分集剧照
            Task {
                let stills = await TMDBEpisodeStillRepository.shared.getEpisodeStills(
                    subjectId: bgmId,
                    episodes: response.data,
                    database: database
                )
                self.episodeStills = stills
            }
        } catch {
            await MainActor.run {
                isEpisodesLoading = false
            }
            print("Failed to load episodes: \(error)")
        }

        if let profile = authenticatedProfile,
           profile.isAuthenticated,
           let bgmUserID = profile.effectiveBgmUserID {
            await refreshBangumiCollectionStates()

            do {
                let localStates = try await AniTVDatabase.localEpisodeWatchStates(
                    bgmUserID: bgmUserID,
                    episodeIDs: episodes.map(\.id),
                    in: database
                )
                await MainActor.run {
                    localResumeSecondsByEpisodeID = Dictionary(
                        uniqueKeysWithValues: localStates.map { ($0.episodeID, $0.playheadSeconds) }
                    )
                }
            } catch {
                print("Failed to load local episode watch states: \(error)")
            }
        } else {
            await MainActor.run {
                subjectCollectionType = nil
                didLoadSubjectCollectionState = false
                userEpisodeCollectionTypesByEpisodeID = [:]
                localResumeSecondsByEpisodeID = [:]
            }
        }

        await MainActor.run {
            if shouldPromptMarkWatchingAfterPlayerExit,
               currentProfile?.isAuthenticated == true,
               didLoadSubjectCollectionState,
               subjectCollectionType == nil {
                showingMarkWatchingPrompt = true
            } else {
                shouldPromptMarkWatchingAfterPlayerExit = false
                showingMarkWatchingPrompt = false
            }
        }
    }

    private func formattedEpisodeNumber(for episode: BgmEpisodeInfo) -> String {
        let value = episode.ep > 0 ? episode.ep : episode.sort
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }

    private func handlePlayButtonTap() {
        guard let episode = firstUnwatchedEpisode else { return }

        Task {
            await openEpisodeFromPrimaryAction(episode)
        }
    }

    private func handleEpisodeCardTap(_ episode: BgmEpisodeInfo) {
        Task {
            await openEpisodeFromEpisodeCard(episode)
        }
    }

    private func handleEpisodeWatchToggle(_ episode: BgmEpisodeInfo) {
        Task {
            await toggleEpisodeWatchStatus(episode)
        }
    }

    private func handleSubjectCollectionMenuSelection(_ collectionType: SubjectCollectionType) {
        Task {
            await updateSubjectCollection(collectionType)
        }
    }

    private func openEpisodeFromPrimaryAction(_ episode: BgmEpisodeInfo) async {
        let resumeSeconds = await loadLocalResumeSeconds(for: episode)
        await MainActor.run {
            guard let resumeSeconds, resumeSeconds > 0 else {
                openEpisodePlayer(episodes, episode, displayName, nil)
                return
            }
            pendingResumePromptEpisode = episode
            pendingResumePromptSeconds = resumeSeconds
        }
    }

    private func openEpisodeFromEpisodeCard(_ episode: BgmEpisodeInfo) async {
        if effectiveIsWatched(for: episode) {
            await MainActor.run {
                openEpisodePlayer(episodes, episode, displayName, nil)
            }
            return
        }

        let resumeSeconds = await loadLocalResumeSeconds(for: episode)
        await MainActor.run {
            guard let resumeSeconds, resumeSeconds > 0 else {
                openEpisodePlayer(episodes, episode, displayName, nil)
                return
            }
            pendingResumePromptEpisode = episode
            pendingResumePromptSeconds = resumeSeconds
        }
    }

    private func toggleEpisodeWatchStatus(_ episode: BgmEpisodeInfo) async {
        guard currentProfile?.isAuthenticated == true else { return }
        let bgmUserID = currentProfile?.effectiveBgmUserID

        let shouldMarkWatched = !effectiveIsWatched(for: episode)
        let repository = BangumiRepository()

        do {
            try await repository.setEpisodeCollectionType(
                episodeID: episode.id,
                type: shouldMarkWatched ? 2 : 0
            )

            if shouldMarkWatched, let bgmUserID {
                try await AniTVDatabase.upsertLocalEpisodeWatchState(
                    bgmUserID: bgmUserID,
                    episodeID: episode.id,
                    type: LocalEpisodeWatchState.watchingType,
                    updatedAt: 0,
                    playheadSeconds: 0,
                    in: database
                )
            }

            if shouldMarkWatched {
                let didFinishAllEpisodes = episodes.allSatisfy { candidate in
                    if candidate.id == episode.id {
                        return true
                    }
                    return effectiveIsWatched(for: candidate)
                }
                let targetSubjectCollectionType =
                    didFinishAllEpisodes
                    ? SubjectCollectionType.collected.rawValue
                    : SubjectCollectionType.watching.rawValue

                if subjectCollectionType != targetSubjectCollectionType {
                    try await repository.setSubjectCollectionType(
                        subjectID: bgmId,
                        type: targetSubjectCollectionType
                    )
                }
            } else if subjectCollectionType == SubjectCollectionType.collected.rawValue {
                try await repository.setSubjectCollectionType(
                    subjectID: bgmId,
                    type: SubjectCollectionType.watching.rawValue
                )
            }

            await MainActor.run {
                localResumeSecondsByEpisodeID[episode.id] = 0
                detailRefreshToken += 1
            }
        } catch {
            print("Failed to update episode watch status: \(error)")
        }
    }

    private func markSubjectAsWatchingIfNeeded() async {
        guard currentProfile?.isAuthenticated == true else { return }

        do {
            try await BangumiRepository().setSubjectCollectionType(
                subjectID: bgmId,
                type: SubjectCollectionType.watching.rawValue
            )
            await MainActor.run {
                shouldPromptMarkWatchingAfterPlayerExit = false
                showingMarkWatchingPrompt = false
                detailRefreshToken += 1
            }
        } catch {
            print("Failed to mark subject as watching: \(error)")
        }
    }

    private func refreshBangumiCollectionStates() async {
        let bgmRepo = BangumiRepository()

        do {
            let collection = try await bgmRepo.currentUserCollection(
                subjectID: bgmId
            )
            await MainActor.run {
                subjectCollectionType = collection?.type
                didLoadSubjectCollectionState = true
            }
        } catch {
            print("Failed to load user subject collection: \(error)")
            await MainActor.run {
                subjectCollectionType = nil
                didLoadSubjectCollectionState = true
            }
        }

        do {
            let collections = try await bgmRepo.fetchUserEpisodeCollections(
                subjectID: bgmId
            )
            await MainActor.run {
                userEpisodeCollectionTypesByEpisodeID = Dictionary(
                    uniqueKeysWithValues: collections.map { ($0.episode.id, $0.type) }
                )
            }
        } catch {
            print("Failed to load user episode collections: \(error)")
        }
    }

    private func updateSubjectCollection(_ collectionType: SubjectCollectionType) async {
        guard currentProfile?.isAuthenticated == true else { return }

        let repository = BangumiRepository()

        do {
            try await repository.setSubjectCollectionType(
                subjectID: bgmId,
                type: collectionType.rawValue
            )

            await refreshBangumiCollectionStates()
            await MainActor.run {
                shouldPromptMarkWatchingAfterPlayerExit = false
                showingMarkWatchingPrompt = false
                detailRefreshToken += 1
            }
        } catch {
            print("Failed to update subject collection: \(error)")
        }
    }

    private func loadLocalResumeSeconds(for episode: BgmEpisodeInfo) async -> Int? {
        if let playheadSeconds = localResumeSecondsByEpisodeID[episode.id], playheadSeconds > 0 {
            return playheadSeconds
        }
        guard let bgmUserID = currentProfile?.effectiveBgmUserID else { return nil }
        do {
            let localState = try await AniTVDatabase.localEpisodeWatchState(
                bgmUserID: bgmUserID,
                episodeID: episode.id,
                in: database
            )
            guard let playheadSeconds = localState?.playheadSeconds, playheadSeconds > 0 else {
                return nil
            }
            await MainActor.run {
                localResumeSecondsByEpisodeID[episode.id] = playheadSeconds
            }
            return playheadSeconds
        } catch {
            print("Failed to load local episode watch state: \(error)")
            return nil
        }
    }

    private func effectiveIsWatched(for episode: BgmEpisodeInfo) -> Bool {
        if let localResumeSeconds = localResumeSecondsByEpisodeID[episode.id], localResumeSeconds > 0 {
            return false
        }
        return watchedEpisodeIDs.contains(episode.id)
    }

}

// 辅助小组件：标签
struct BadgeView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.white.opacity(0.2))
            .cornerRadius(4)
    }
}

private extension SubjectCollectionType {
    var title: String {
        switch self {
        case .wish:
            return "想看"
        case .collected:
            return "看过"
        case .watching:
            return "在看"
        case .onHold:
            return "搁置"
        case .dropped:
            return "抛弃"
        }
    }

    var systemImage: String {
        switch self {
        case .wish:
            return "calendar.badge.plus"
        case .collected:
            return "checkmark.circle"
        case .watching:
            return "livephoto.play"
        case .onHold:
            return "clock.badge.questionmark"
        case .dropped:
            return "slash.circle"
        }
    }
}


extension SelectorMediaSourceArguments {
    static var mock: SelectorMediaSourceArguments {
        let json = #"""
{
          "name": "omofun111",
          "description": "直连，来自omofun动漫视频网，导航：https://enlienli.link/",
          "iconUrl": "https://enlienli.link/upload/mxprocms/20230707-1/49f4b8a7fd5cbf77ffcfa7a52e755675.gif",
          "searchConfig": {
            "searchUrl": "https://enlienli.link/vod/search.html?wd={keyword}",
            "searchUseOnlyFirstWord": true,
            "subjectFormatId": "a",
            "selectorSubjectFormatA": {
              "selectLists": ".module-card-item>.module-card-item-info>.module-card-item-title>a",
              "preferShorterName": false
            },
            "channelFormatId": "index-grouped",
            "selectorChannelFormatFlattened": {
              "selectChannelNames": "div>div>div>div>div>div.module-tab-items-box>.module-tab-item>span",
              "matchChannelName": "(?!高清线路3)",
              "selectEpisodeLists": ".module-play-list-content",
              "selectEpisodesFromList": "a",
              "selectEpisodeLinksFromList": "",
              "matchEpisodeSortFromName": "第\\s*(?<ep>.+)\\s*[话集]"
            },
            "defaultResolution": "1080P",
            "defaultSubtitleLanguage": "CHS",
            "onlySupportsPlayers": [],
            "selectMedia": {
              "distinguishSubjectName": true,
              "distinguishChannelName": true
            },
            "matchVideo": {
              "enableNestedUrl": true,
              "matchNestedUrl": "$^",
              "matchVideoUrl": "(^http(s)?:\\/\\/(?!.*http).+\\.(mp4|m3u8|flv|mkv))|(url=(?<v>http(s)?:\\/\\/.+\\.(mp4|m3u8|flv|mkv)))|(^http(s)?:\\/\\/(?!.*http).+(sign\\.bytetos|sign\\.byteimg|mcloud\\.139|cloudflarestorage|tos-cn)\\.com(?!.*\\.ts).+(-expires|-signature))|((bilivideo|akamaized|szbdyd)\\.com(?!.*\\.ts))|(\\/video\\/tos\\/alisg\\/)|(\\/video\\/.*mime_type=video)",
              "cookies": "",
              "addHeadersToVideo": {
                "referer": "",
"userAgent":""
              }
            }
          },
          "tier": 0
        }
"""#.data(using: .utf8)!
        
        return try! JSONDecoder().decode(SelectorMediaSourceArguments.self, from: json)
    }
}


struct AnimeDetailView_Previews: PreviewProvider {
    static var previews: some View {
        AnimeDetailView(bgmId: 515759, openEpisodePlayer: { _, _, _, _ in })
        .previewDevice("Apple TV 4K (3rd generation)")
    }
}
