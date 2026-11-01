//
//  StarRatingView.swift
//  AniTV
//
//  Created by Feiran Yang on 2026/2/13.
//


import SwiftUI

// 定义图片中的主色调
extension Color {
    static let bangumiPurple = Color(red: 0.45, green: 0.35, blue: 0.55) // #73598C
    static let bangumiTextGray = Color(red: 0.5, green: 0.5, blue: 0.55) // #80808C
}

// MARK: - 星星视图组件
struct StarRatingView: View {
    let score: Double // 10分制
    
    private var fiveStarScore: Double { Double(String(format: "%.1f", score))! / 2.0 }
    private var fullStars: Int { Int(fiveStarScore) }
    private var hasHalfStar: Bool {
        let remainder = fiveStarScore.truncatingRemainder(dividingBy: 1)
        // 这里为了简单，直接用系统图标，不做复杂的四舍五入
        return remainder >= 0.5
    }
    private var emptyStars: Int { 5 - fullStars - (hasHalfStar ? 1 : 0) }
    
    var body: some View {
        HStack(spacing: 4) {
            // 实心星
            ForEach(0..<fullStars, id: \.self) { _ in
                Image(systemName: "star.fill")
            }
            // 半心星
            if hasHalfStar {
                Image(systemName: "star.leadinghalf.filled")
            }
            // 空心星
            ForEach(0..<emptyStars, id: \.self) { _ in
                Image(systemName: "star")
            }
        }
        .font(.headline) // 星星大小
//        .foregroundColor(.bangumiPurple)
    }
}

// MARK: - 完整评分视图组件
struct ScoreView: View {
    let score: Double
    let count: Int
    let rank: Int
    
    private var scoreString: String {
        String(format: "%.1f", score)
    }

    private var scoreDescription: String {
        guard score > 0 else { return "" }
        let roundedScore = min(max(Int(score.rounded()), 1), 10)
        let descriptions = [
            1: "不忍直视",
            2: "很差",
            3: "差",
            4: "较差",
            5: "不过不失",
            6: "还行",
            7: "推荐",
            8: "力荐",
            9: "神作",
            10: "超神作"
        ]
        return descriptions[roundedScore] ?? ""
    }
    
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            // 左侧大数字
            Text(scoreString)
                .font(.system(size: 48, weight: .bold, design: .rounded))
//                .foregroundColor(.bangumiPurple)
            
            // 右侧信息
            VStack(spacing: 4) {
                // 第一行：星星
                StarRatingView(score: score)
                
                // 第二行：人数和排名
                HStack(spacing: 8) {
                    Text("\(count) 人评")
                    if rank > 0 {
                        Text("|")
                        Text("#\(rank)")
                    }
                }
                .font(.body)
                .foregroundColor(.white)
            }
            .padding(.top, 8) // 微调对齐
            
            if !scoreDescription.isEmpty {
                Text(scoreDescription)
                    .font(.system(size: 48, weight: .bold, design: .rounded))
            }
        }
    }
}
