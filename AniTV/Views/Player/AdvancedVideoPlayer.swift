//
//  AdvancedVideoPlayer.swift
//  AniTV
//
//  Created by Feiran Yang on 2026/3/16.
//


import SwiftUI
import AVKit

final class AniTVPlayerViewController: AVPlayerViewController {
    var onUpArrowWhenControlsVisible: (() -> Void)?
    var onExitRequest: (() -> Void)?
    var shouldIgnoreUpArrow = false
    var isSourcePanelPresented = false

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let isMenu = presses.contains(where: { $0.type == .menu })
        let isUpArrow = presses.contains(where: { $0.type == .upArrow })

        if isMenu {
            if isSourcePanelPresented {
                super.pressesEnded(presses, with: event)
                return
            }

            if arePlaybackControlsLikelyVisible(in: view) {
                super.pressesEnded(presses, with: event)
                return
            }

            super.pressesEnded(presses, with: event)
            DispatchQueue.main.async { [weak self] in
                self?.onExitRequest?()
            }
            return
        }

        super.pressesEnded(presses, with: event)

        guard !shouldIgnoreUpArrow else { return }
        guard isUpArrow else { return }
        guard arePlaybackControlsLikelyVisible(in: view) else { return }

        DispatchQueue.main.async { [weak self] in
            self?.onUpArrowWhenControlsVisible?()
        }
    }

    private func arePlaybackControlsLikelyVisible(in rootView: UIView) -> Bool {
        let className = String(describing: type(of: rootView))
        let looksLikeControlsView =
            className.localizedCaseInsensitiveContains("transport") ||
            className.localizedCaseInsensitiveContains("control") ||
            className.localizedCaseInsensitiveContains("playback")

        if looksLikeControlsView,
           !rootView.isHidden,
           rootView.alpha > 0.01,
           rootView.bounds.width > 0,
           rootView.bounds.height > 0 {
            return true
        }

        for subview in rootView.subviews {
            if arePlaybackControlsLikelyVisible(in: subview) {
                return true
            }
        }

        return false
    }
}

struct VideoSource {
    let sourceName: String
    let resources: [VideoResource]
}

struct VideoResource {
    let resourceName: String
    let url: String
//    let headers: [String: String]
    let matchConfig: SelectorSearchConfig.MatchVideoConfig
}

struct AdvancedVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    let title: String
    let sort: Int
    var availableSources: [VideoSource]
    @Binding var isSourcePanelPresented: Bool
    var danmuManager: DanmuViewManager?
    var isDanmakuAvailable: Bool = true
    var onExitRequest: (() -> Void)? = nil
    var onDanmakuToggled: ((Bool) -> Void)? = nil
    
    // 选中的线路回调（如果需要通知外部去切换 m3u8）
    var onSourceSelected: ((Int, Int, VideoResource) -> Void)?
    
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var pipController: AVPictureInPictureController?
        let sourcePanelModel = SourceSwitchPanelModel()
        var detailsHostingController: UIHostingController<AniTVCustomDropdownView>?
        weak var currentDanmuManager: DanmuViewManager?
        var isDanmakuEnabled: Bool = AniTVDatabase.resolvedInitialDanmakuEnabled()
        var selectedDisplayArea: CGFloat = 1.0
        weak var controller: AVPlayerViewController?

        // MARK: - AVPlayerViewControllerDelegate
        func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ playerViewController: AVPlayerViewController) -> Bool {
            return false
        }

        func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            print("[AdvancedVideoPlayer] PiP will start")
        }

        func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            print("[AdvancedVideoPlayer] PiP did start")
        }

        func playerViewController(_ playerViewController: AVPlayerViewController, failedToStartPictureInPictureWithError error: Error) {
            print("[AdvancedVideoPlayer] PiP failed to start: \(error.localizedDescription)")
        }

        func playerViewControllerWillStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            print("[AdvancedVideoPlayer] PiP will stop")
        }

        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            print("[AdvancedVideoPlayer] PiP did stop")
        }

        func playerViewController(_ playerViewController: AVPlayerViewController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            print("[AdvancedVideoPlayer] PiP restore UI requested")
            completionHandler(true)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    private func setupDanmuManagerIfNeeded(controller: AVPlayerViewController, context: Context) {
        guard let danmuManager = danmuManager, context.coordinator.currentDanmuManager !== danmuManager else { return }
        context.coordinator.currentDanmuManager = danmuManager
        danmuManager.isEnabled = context.coordinator.isDanmakuEnabled
        danmuManager.displayArea = context.coordinator.selectedDisplayArea
        if let overlayView = controller.contentOverlayView {
            print("[AdvancedVideoPlayer] Attaching danmuManager to contentOverlayView with bounds: \(overlayView.bounds)")
            danmuManager.setup(with: player, in: overlayView)
        } else {
            print("[AdvancedVideoPlayer] Warning: contentOverlayView is nil")
        }
    }

    private func setupPipControllerIfNeeded(controller: AVPlayerViewController, context: Context) {
        if context.coordinator.pipController == nil {
            if let internalPip = controller.value(forKey: "pictureInPictureController") as? AVPictureInPictureController {
                context.coordinator.pipController = internalPip
            } else if let playerLayer = findPlayerLayer(in: controller.view.layer), AVPictureInPictureController.isPictureInPictureSupported() {
                context.coordinator.pipController = AVPictureInPictureController(playerLayer: playerLayer)
            }
        }
    }
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AniTVPlayerViewController()
        controller.player = player
        controller.delegate = context.coordinator
        controller.allowsPictureInPicturePlayback = true
        context.coordinator.controller = controller
        controller.appliesPreferredDisplayCriteriaAutomatically = false
        controller.showsPlaybackControls = !isSourcePanelPresented
        controller.shouldIgnoreUpArrow = isSourcePanelPresented
        controller.isSourcePanelPresented = isSourcePanelPresented
        controller.onExitRequest = onExitRequest
        controller.onUpArrowWhenControlsVisible = {
            guard !isSourcePanelPresented else { return }
            isSourcePanelPresented = true
        }
        let detailsHostingController = UIHostingController(rootView: AniTVCustomDropdownView(title: title, sort: sort))
        detailsHostingController.view.backgroundColor = .clear
        detailsHostingController.title = String(localized: .nextUp)
        context.coordinator.detailsHostingController = detailsHostingController

        context.coordinator.sourcePanelModel.update(sources: availableSources, onSourceSelected: onSourceSelected)
        controller.customInfoViewControllers = [detailsHostingController]
        
        let startOverAction = UIAction(
                title: "从头开始", // 或者 "从头播放"
                image: UIImage(systemName: "arrow.counterclockwise") // 苹果原生常用的重播图标
            ) { _ in
                // 核心逻辑：将播放器的进度拨回起点，并确保继续播放
                controller.player?.seek(to: .zero)
                controller.player?.play()
            }
        
        let favoriteAction = UIAction(
            title: "加入追番",
            image: UIImage(systemName: "heart.fill")
        ) { _ in
            print("触发了追番逻辑！")
        }
        
        controller.loadViewIfNeeded()
        setupPipControllerIfNeeded(controller: controller, context: context)
        setupDanmuManagerIfNeeded(controller: controller, context: context)
        
        controller.infoViewActions = [startOverAction, favoriteAction]
        controller.transportBarCustomMenuItems = [getSourcePanelAction(), getPipAction(uiViewController: controller, context: context), getDanmakuMenu(uiViewController: controller, context: context)]
        return controller
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        uiViewController.player = player
        uiViewController.delegate = context.coordinator
        uiViewController.allowsPictureInPicturePlayback = true
        context.coordinator.controller = uiViewController
        if let controller = uiViewController as? AniTVPlayerViewController {
            uiViewController.showsPlaybackControls = !isSourcePanelPresented
            controller.shouldIgnoreUpArrow = isSourcePanelPresented
            controller.isSourcePanelPresented = isSourcePanelPresented
            controller.onExitRequest = onExitRequest
            controller.onUpArrowWhenControlsVisible = {
                guard !isSourcePanelPresented else { return }
                isSourcePanelPresented = true
            }
            setupDanmuManagerIfNeeded(controller: controller, context: context)
        }
        setupPipControllerIfNeeded(controller: uiViewController, context: context)
        context.coordinator.detailsHostingController?.rootView = AniTVCustomDropdownView(title: title, sort: sort)
        context.coordinator.sourcePanelModel.update(sources: availableSources, onSourceSelected: onSourceSelected)
        uiViewController.transportBarCustomMenuItems = [getSourcePanelAction(), getPipAction(uiViewController: uiViewController, context: context), getDanmakuMenu(uiViewController: uiViewController, context: context)]
    }

    private func getDanmakuMenu(uiViewController: AVPlayerViewController, context: Context) -> UIMenu {
        let isEnabled = context.coordinator.isDanmakuEnabled && isDanmakuAvailable
        let currentArea = context.coordinator.selectedDisplayArea
        
        let toggleAction = UIAction(
            title: isDanmakuAvailable ? "弹幕开关" : "获取弹幕失败",
            attributes: isDanmakuAvailable ? [] : [.disabled],
            state: isEnabled ? .on : .off
        ) { _ in
            guard isDanmakuAvailable else { return }
            context.coordinator.isDanmakuEnabled.toggle()
            let newEnabled = context.coordinator.isDanmakuEnabled
            danmuManager?.isEnabled = newEnabled
            onDanmakuToggled?(newEnabled)
            uiViewController.transportBarCustomMenuItems = [
                getSourcePanelAction(),
                getPipAction(uiViewController: uiViewController, context: context),
                getDanmakuMenu(uiViewController: uiViewController, context: context)
            ]
        }
        
        let areaOptions: [(title: String, area: CGFloat)] = [
            ("全屏", 1.0),
            ("3/4", 0.75),
            ("1/2", 0.5),
            ("1/4", 0.25),
            ("1/8", 0.125)
        ]
        
        let areaActions = areaOptions.map { item in
            UIAction(
                title: item.title,
                attributes: isDanmakuAvailable ? [] : [.disabled],
                state: (abs(currentArea - item.area) < 0.01) ? .on : .off
            ) { _ in
                guard isDanmakuAvailable else { return }
                context.coordinator.selectedDisplayArea = item.area
                danmuManager?.displayArea = item.area
                uiViewController.transportBarCustomMenuItems = [
                    getSourcePanelAction(),
                    getPipAction(uiViewController: uiViewController, context: context),
                    getDanmakuMenu(uiViewController: uiViewController, context: context)
                ]
            }
        }
        
        let submenu = UIMenu(
            title: "弹幕区域",
            options: [.displayInline, .singleSelection],
            children: areaActions
        )
        
        let image = UIImage(systemName: isEnabled ? "text.bubble.fill" : "text.bubble")
        
        return UIMenu(
            title: "弹幕",
            image: image,
            children: [toggleAction, submenu]
        )
    }

    private func getSourcePanelAction() -> UIAction {
        UIAction(
            title: "线路",
            image: UIImage(systemName: "list.bullet.rectangle")
        ) { _ in
            isSourcePanelPresented.toggle()
        }
    }
    
    private func getPipAction(uiViewController: AVPlayerViewController, context: Context) -> UIAction {
        return UIAction(
            title: "画中画",
            image: UIImage(systemName: "pip")
        ) { [weak uiViewController] _ in
            guard let controller = uiViewController else { return }
            
            setupPipControllerIfNeeded(controller: controller, context: context)
            
            let startSel = Selector(("startPictureInPicture"))
            let stopSel = Selector(("stopPictureInPicture"))
            let isPiPActive = (controller.value(forKey: "isPictureInPictureActive") as? Bool) ?? (context.coordinator.pipController?.isPictureInPictureActive ?? false)

            if isPiPActive {
                if controller.responds(to: stopSel) {
                    _ = controller.perform(stopSel)
                } else if let pipController = context.coordinator.pipController {
                    pipController.stopPictureInPicture()
                }
            } else {
                if controller.responds(to: startSel) {
                    _ = controller.perform(startSel)
                } else if let pipController = context.coordinator.pipController {
                    if pipController.isPictureInPicturePossible {
                        pipController.startPictureInPicture()
                    } else {
                        print("[PiP] AVPictureInPictureController 暂不可用")
                    }
                } else {
                    print("[PiP] 画中画功能在此设备上不可用")
                }
            }
        }
    }
    
    private func findPlayerLayer(in layer: CALayer) -> AVPlayerLayer? {
        if let playerLayer = layer as? AVPlayerLayer {
            return playerLayer
        }
        guard let sublayers = layer.sublayers else { return nil }
        for sublayer in sublayers {
            if let match = findPlayerLayer(in: sublayer) {
                return match
            }
        }
        return nil
    }
}
