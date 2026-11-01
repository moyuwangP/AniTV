//
//  EpisodeCardView.swift
//  AniTV
//
//  Created by Feiran Yang on 2026/2/13.
//


import SwiftUI
import Kingfisher

struct EpisodeCardView: View {
    let episodeInfo: BgmEpisodeInfo
    let sessionTitle: String
    let stillURL: URL? // 单集截图
    let isWatched: Bool
    let onOpenPlayer: () -> Void
    let onToggleWatched: () -> Void
    
    var body: some View {
        Button(action: onOpenPlayer) {
            VStack(alignment: .leading, spacing: 0) {
                if let stillURL {
                    KFImage(stillURL)
                        .resizable()
                        .placeholder {
                            placeholderView
                        }
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 320, height: 180) // 经典的 16:9 尺寸
                        .clipped()
                } else {
                    placeholderView
                        .frame(width: 320, height: 180)
                }
                
                
                // 2. 剧集标题/集数
                VStack(alignment: .leading) {
                    Text("\(isWatched ? "✓ " : "")第 \(Int(episodeInfo.ep)) 话")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .opacity(0.8)
                    
                    Text(episodeInfo.name)
                        .font(.caption)
                        .lineLimit(1)
                        .opacity(0.6)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial) // 毛玻璃效果
            }
        }
        .buttonStyle(.card) // tvOS 自带的卡片样式，自带视差和光效
        .frame(width: 320)
        .contextMenu {
            Button(isWatched ? "撤销观看状态" : "标记为已观看", action: onToggleWatched)
        }
        // 注意：使用了 .card 样式后，不需要手动写 scaleEffect，系统会自动处理
    }

    private var placeholderView: some View {
        ZStack {
            Color.gray.opacity(0.3)
            Image(systemName: "photo.badge.questionmark")
                .font(.title)
                .foregroundColor(.white.opacity(0.5))
        }
    }
}
