import XCTest
@testable import VPNNavigatorCore

final class ProfileLibraryQueryTests: XCTestCase {
    private func profile(_ name: String, group: String = "个人", favorite: Bool = false, date: TimeInterval = 1) -> VPNProfile {
        VPNProfile(name: name, sourceFilename: name + ".ovpn", relativePath: "private-path",
                   importedAt: Date(timeIntervalSince1970: date), group: group, notes: "private-note", isFavorite: favorite)
    }
    func testFavoritesAndGroupComposeWithFoldedAllTokenSearch() {
        let a = profile("Café Work", group: "研发", favorite: true), b = profile("Work", group: "家庭")
        XCTAssertEqual(ProfileLibraryQuery(query: "研发 ＣＡＦＥ", scope: .favorites).results([a, b]), [a])
        XCTAssertEqual(ProfileLibraryQuery(query: "work ovpn", scope: .group("研发")).results([a, b]), [a])
        XCTAssertTrue(ProfileLibraryQuery(query: "家庭", scope: .favorites).results([a, b]).isEmpty)
    }
    func testSearchNeverReadsNotesOrPathsAndIsBounded() {
        let a = profile("A")
        for value in ["private-note", "private-path", String(repeating: "x", count: 257)] {
            XCTAssertTrue(ProfileLibraryQuery(query: value).results([a]).isEmpty)
        }
    }
    func testGroupCountsTrimWhitespaceAndIgnoreEmptyGroups() {
        let a = profile("A", group: " 工作 "), b = profile("B", group: "工作"), c = profile("C", group: " ")
        let groups = ProfileLibraryQuery.groups([a, b, c])
        XCTAssertEqual(groups.map(\.name), ["工作"]); XCTAssertEqual(groups.map(\.count), [2])
        XCTAssertEqual(Set(ProfileLibraryQuery(scope: .group(" 工作 ")).results([a, b, c]).map(\.id)), Set([a.id, b.id]))
    }
    func testMissingGroupFallsBackButExplicitEmptyFavoritesDoesNot() {
        let a = profile("A", group: "工作")
        var query = ProfileLibraryQuery(query: "A", scope: .group("旧组"), sort: .newest)
        query.reconcileGroups([a]); XCTAssertEqual(query.scope, .all)
        XCTAssertEqual(query.query, "A"); XCTAssertEqual(query.sort, .newest)
        query.scope = .favorites; query.reconcileGroups([a])
        XCTAssertEqual(query.scope, .favorites); XCTAssertTrue(query.results([a]).isEmpty)
    }
    func testNameSortIsNaturalAndDuplicateNamesHaveStableOrder() {
        let a = profile("Node 10", favorite: true), b = profile("Node 2"), c = profile("Node 2")
        let query = ProfileLibraryQuery(sort: .name)
        let result = query.results([a, b, c])
        XCTAssertEqual(result.last, a)
        XCTAssertEqual(result, query.results([c, b, a]))
    }
    func testNewestUsesImportTimeAndStableNameTies() {
        let old = profile("Old", date: 1), a = profile("A", date: 3), b = profile("B", date: 3)
        XCTAssertEqual(ProfileLibraryQuery(sort: .newest).results([old, b, a]), [a, b, old])
    }
    func testRecommendedKeepsExactPrefixFavoriteRanking() {
        let exact = profile("Work"), prefix = profile("Workshop"), favorite = profile("My Work", favorite: true)
        XCTAssertEqual(ProfileLibraryQuery(query: "Work").results([favorite, prefix, exact]), [exact, prefix, favorite])
        XCTAssertEqual(ProfileLibraryQuery().results([prefix, exact, favorite]).first, favorite)
    }
    func testGroupChoicesReuseCustomNamesAndBoundDrafts() {
        let a = profile("A", group: " 研发 "), b = profile("B", group: "研发")
        let choices = ProfileLibraryQuery.groupChoices([a, b], current: " 新组 ")
        XCTAssertEqual(choices.filter { $0 == "研发" }.count, 1)
        XCTAssertTrue(choices.contains("新组")); XCTAssertTrue(choices.contains("个人"))
        XCTAssertFalse(ProfileLibraryQuery.groupChoices([], current: String(repeating: "中", count: 49)).contains { $0.count > 48 })
        XCTAssertEqual(choices, ProfileLibraryQuery.groupChoices([b, a], current: "新组"))
    }
    func testClearingFiltersPreservesSortAndDoesNotInventASelection() {
        let a = profile("A"), b = profile("B", favorite: true)
        var query = ProfileLibraryQuery(query: "B", scope: .favorites, sort: .name)
        XCTAssertNil(query.selectedProfile(a.id, in: [a, b]))
        XCTAssertEqual(query.selectedProfile(b.id, in: [a, b]), b)
        query.clearFilters()
        XCTAssertEqual(query.scope, .all); XCTAssertTrue(query.query.isEmpty); XCTAssertEqual(query.sort, .name)
        XCTAssertEqual(query.selectedProfile(a.id, in: [a, b]), a)
        XCTAssertNil(query.selectedProfile(UUID(), in: [a, b]))
    }
    func testUnknownSavedSortFallsBackAndKnownValuesRoundTrip() {
        XCTAssertEqual(ProfileLibrarySort(savedValue: nil), .recommended)
        XCTAssertEqual(ProfileLibrarySort(savedValue: "unknown"), .recommended)
        for sort in ProfileLibrarySort.allCases { XCTAssertEqual(ProfileLibrarySort(savedValue: sort.rawValue), sort) }
    }
}
