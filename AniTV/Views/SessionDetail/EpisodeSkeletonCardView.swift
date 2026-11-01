//
//  EpisodeSkeletonCardView.swift
//  AniTV
//
//  Created by Codex on 2026/11/1.
//

import SwiftUI

struct EpisodeSkeletonCardView: View {
    @State private var isAnimating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 16:9 占位封面
            Rectangle()
                .fill(Color.white.opacity(isAnimating ? 0.16 : 0.08))
                .frame(width: 320, height: 180)
            
            // 下方文字占位
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(isAnimating ? 0.28 : 0.16))
                    .frame(width: 70, height: 18)
                
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(isAnimating ? 0.20 : 0.10))
                    .frame(width: 190, height: 14)
            }
            .padding(14)
            .frame(width: 320, alignment: .leading)
            .background(Color.white.opacity(0.06))
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear {
            withAnimation(
                .easeInOut(duration: 1.1)
                .repeatForever(autoreverses: true)
            ) {
                isAnimating = true
            }
        }
    }
}
