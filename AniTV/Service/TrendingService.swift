//
//  TrendingService.swift
//  AniTV
//
//  Created by Codex on 2026/4/8.
//

import Foundation
import SQLiteData

struct TrendingBackdropDTO: Identifiable, Sendable {
    let subject: TrendingSubjectDTO
    let backdropImage: String

    var id: Int { subject.id }
}

struct TrendingService: Sendable {
    private let bgmRepository = BangumiRepository()
    private let tmdbRepository = TMDBRepository()

    func fetchTrendingSubjectsWithBackdrop(
        database: any DatabaseWriter
    ) async throws -> [TrendingBackdropDTO] {
        let response = try await bgmRepository.fetchTrendingSubjects()
        var tmdbBackdropBySubjectID: [Int: String] = [:]
        var missingTMDBSubjectIDs: [Int] = []
        missingTMDBSubjectIDs.reserveCapacity(response.data.count)

        for entry in response.data {
            let subjectID = entry.subject.id

            let tmdbBackdrop = await tmdbRepository.getBackdrop(subjectId: subjectID)
            if !tmdbBackdrop.isEmpty {
                tmdbBackdropBySubjectID[subjectID] = tmdbBackdrop
                continue
            }

            missingTMDBSubjectIDs.append(subjectID)
        }

        let bangumiBackdropBySubjectID = try await bgmRepository.fetchLargeImages(subjectIDs: missingTMDBSubjectIDs)

        return response.data.map { entry in
            let subjectID = entry.subject.id
            let backdropImage = tmdbBackdropBySubjectID[subjectID]
                ?? bangumiBackdropBySubjectID[subjectID]
                ?? entry.subject.images.large

            return TrendingBackdropDTO(
                subject: entry,
                backdropImage: backdropImage
            )
        }
    }

}
