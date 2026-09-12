import XCTest
@testable import CodeRelayClient

final class SessionNamingTests: XCTestCase {

    // MARK: - Theme catalog

    func testEveryThemeHasNames() {
        for theme in SessionNamingTheme.allCases {
            XCTAssertFalse(
                theme.names.isEmpty,
                "Theme \(theme.displayName) has empty name list"
            )
        }
    }

    func testEveryThemeHasAtLeastTenNames() {
        for theme in SessionNamingTheme.allCases {
            XCTAssertGreaterThanOrEqual(
                theme.names.count, 10,
                "Theme \(theme.displayName) should have at least 10 names to avoid frequent fallback"
            )
        }
    }

    func testAllThemesIdMatchesRawValue() {
        for theme in SessionNamingTheme.allCases {
            XCTAssertEqual(theme.id, theme.rawValue)
        }
    }

    func testThemeRawValuesAreStable() {
        // These raw values are persisted by @AppStorage on both iOS and Mac.
        // Renaming them requires a migration — this test prevents accidental rename.
        XCTAssertEqual(SessionNamingTheme.gameOfThrones.rawValue, "gameOfThrones")
        XCTAssertEqual(SessionNamingTheme.viking.rawValue, "viking")
        XCTAssertEqual(SessionNamingTheme.starWars.rawValue, "starWars")
        XCTAssertEqual(SessionNamingTheme.dune.rawValue, "dune")
        XCTAssertEqual(SessionNamingTheme.lordOfTheRings.rawValue, "lordOfTheRings")
        XCTAssertEqual(SessionNamingTheme.starTrek.rawValue, "starTrek")
    }

    func testStarTrekPoolHasReasonableSize() {
        // Star Trek is documented at ~76 names in the design spec.
        // Floor of 50 guards against accidental truncation that would
        // cause early "Session N" fallback while leaving room to prune
        // a few names without churning the test.
        XCTAssertGreaterThanOrEqual(
            SessionNamingTheme.starTrek.names.count, 50,
            "Star Trek pool unexpectedly small — \(SessionNamingTheme.starTrek.names.count) names"
        )
    }

    // MARK: - pickDefaultName

    func testPickPrefersUnusedNames() {
        let theme = SessionNamingTheme.starWars
        // All but one name is in use
        let used = Set(theme.names.dropLast())
        let expected = theme.names.last!
        let picked = SessionNaming.pickDefaultName(
            usedNames: used,
            theme: theme,
            fallbackIndex: 1
        )
        XCTAssertEqual(picked, expected)
    }

    func testPickFallsBackWhenAllNamesUsed() {
        let theme = SessionNamingTheme.viking
        let used = Set(theme.names)
        let picked = SessionNaming.pickDefaultName(
            usedNames: used,
            theme: theme,
            fallbackIndex: 42
        )
        XCTAssertEqual(picked, "Session 42")
    }

    func testPickFromEmptyUsedNamesReturnsThemeName() {
        let theme = SessionNamingTheme.dune
        let picked = SessionNaming.pickDefaultName(
            usedNames: [],
            theme: theme,
            fallbackIndex: 1
        )
        XCTAssertTrue(theme.names.contains(picked), "Picked name '\(picked)' not in \(theme.displayName) pool")
    }

    func testFallbackLabelFormat() {
        let theme = SessionNamingTheme.lordOfTheRings
        let used = Set(theme.names)
        XCTAssertEqual(
            SessionNaming.pickDefaultName(usedNames: used, theme: theme, fallbackIndex: 1),
            "Session 1"
        )
        XCTAssertEqual(
            SessionNaming.pickDefaultName(usedNames: used, theme: theme, fallbackIndex: 100),
            "Session 100"
        )
    }
}
