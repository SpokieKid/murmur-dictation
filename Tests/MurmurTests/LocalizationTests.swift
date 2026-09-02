import XCTest
@testable import Murmur

final class LocalizationTests: XCTestCase {
    private var originalLanguage: Any?

    override func setUp() {
        super.setUp()
        originalLanguage = UserDefaults.standard.object(forKey: "appLanguage")
    }

    override func tearDown() {
        if let originalLanguage {
            UserDefaults.standard.set(originalLanguage, forKey: "appLanguage")
        } else {
            UserDefaults.standard.removeObject(forKey: "appLanguage")
        }
        super.tearDown()
    }

    func testExplicitLanguageSwitchesWithoutRelaunch() {
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: "appLanguage")
        XCTAssertEqual(L10n.tr("menu.include_computer_audio"), "Include Computer Audio")

        UserDefaults.standard.set(AppLanguage.simplifiedChinese.rawValue, forKey: "appLanguage")
        XCTAssertEqual(L10n.tr("menu.include_computer_audio"), "收录电脑声音")
    }

    func testLocalizedFormatting() {
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: "appLanguage")
        XCTAssertEqual(L10n.format("hud.hidden_processing", 3), "+3 processing")

        UserDefaults.standard.set(AppLanguage.simplifiedChinese.rawValue, forKey: "appLanguage")
        XCTAssertEqual(L10n.format("hud.hidden_processing", 3), "+3 个处理中")
    }

    func testPinnedTargetStringsExistInBothLanguages() {
        for language in [AppLanguage.english, AppLanguage.simplifiedChinese] {
            UserDefaults.standard.set(language.rawValue, forKey: "appLanguage")
            XCTAssertFalse(L10n.tr("settings.lock_input_target").isEmpty)
            XCTAssertFalse(L10n.tr("settings.lock_input_target_hint").isEmpty)
            XCTAssertFalse(L10n.tr("hud.target_unavailable_copied").isEmpty)
        }
    }
}
