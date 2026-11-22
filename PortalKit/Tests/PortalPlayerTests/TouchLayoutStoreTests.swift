import XCTest
@testable import PortalPlayer

final class TouchLayoutStoreTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "touch-layout-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testUnsetIsTheFallback() {
        let d = defaults()
        XCTAssertEqual(TouchLayoutStore(defaults: d).layout(for: "FAKE000000000000"), .flat)
        XCTAssertEqual(TouchLayoutStore(defaults: d, fallback: .full).layout(for: "FAKE000000000000"), .full)
    }

    func testAChoiceSurvivesANewStoreAndBelongsToItsTitle() {
        let d = defaults()
        TouchLayoutStore(defaults: d).set(.full, for: "FAKE000000000000")
        XCTAssertEqual(TouchLayoutStore(defaults: d).layout(for: "FAKE000000000000"), .full)
        XCTAssertEqual(TouchLayoutStore(defaults: d).layout(for: "FAKE000000000001"), .flat)
        TouchLayoutStore(defaults: d).set(.flat, for: "FAKE000000000000")
        XCTAssertEqual(TouchLayoutStore(defaults: d, fallback: .full).layout(for: "FAKE000000000000"), .flat, "a choice beats the fallback")
    }

    func testAnUnreadableValueIsTheFallback() {
        let d = defaults()
        d.set("sideways", forKey: "touchLayout.FAKE000000000000")
        XCTAssertEqual(TouchLayoutStore(defaults: d, fallback: .full).layout(for: "FAKE000000000000"), .full)
    }

    func testTheKeyIsPerTitle() {
        let d = defaults()
        TouchLayoutStore(defaults: d).set(.full, for: "FAKE000000000000")
        XCTAssertEqual(d.string(forKey: "touchLayout.FAKE000000000000"), "3d")
    }

    func testNothingIsStoredUnderAnEmptyTitle() {
        let d = defaults()
        let store = TouchLayoutStore(defaults: d)
        store.set(.full, for: "")
        XCTAssertEqual(store.layout(for: ""), .flat)
        XCTAssertEqual(store.layout(for: "FAKE000000000000"), .flat, "no other game picked it up")
        XCTAssertNil(d.string(forKey: "touchLayout."))
    }
}
