import XCTest

final class FakeDataTests: XCTestCase {

    // MARK: - Word matching precedence (spec-pinned cases)

    func testFirstNameBeatsFullName() {
        XCTAssertEqual(FakeData.value(for: "$user->first_name"), "Jane")
    }

    func testLastNameYieldsSurname() {
        XCTAssertEqual(FakeData.value(for: "$user->last_name"), "Doe")
    }

    func testUserIdYieldsNumberNotName() {
        XCTAssertEqual(FakeData.value(for: "$user_id"), "42")
    }

    func testUsernameYieldsFullName() {
        XCTAssertEqual(FakeData.value(for: "$username"), "Jane Doe")
    }

    func testCreatedAtYieldsDate() {
        XCTAssertEqual(FakeData.value(for: "$post->created_at"), "Jun 12, 2026")
    }

    func testVideoFallsBackToGeneric() {
        XCTAssertEqual(FakeData.value(for: "$video"), "Sample")
    }

    // MARK: - Expression parsing

    func testTrailingMethodCallIgnored() {
        // format(…) is a call, created_at is the value-bearing segment.
        XCTAssertEqual(FakeData.value(for: "$user->created_at->format('M d, Y')"), "Jun 12, 2026")
    }

    func testAuthChainYieldsName() {
        XCTAssertEqual(FakeData.value(for: "auth()->user()->name"), "Jane Doe")
    }

    func testCamelCaseSplits() {
        XCTAssertEqual(FakeData.value(for: "$createdAt"), "Jun 12, 2026")
    }

    func testOldHelperUsesItsKey() {
        XCTAssertEqual(FakeData.value(for: "old('email')"), "jane@example.com")
    }

    func testConfigHelperUsesLastKeySegment() {
        // config('app.name') → key "app.name" → segment "name".
        XCTAssertEqual(FakeData.value(for: "config('app.name')"), "Jane Doe")
    }

    func testQuotedLiteralsNeverMatch() {
        // 'email' is a string literal argument of an unknown helper, not an identifier.
        XCTAssertEqual(FakeData.value(for: "arr_get($data, 'x')"), "Sample")
    }

    // MARK: - Personas / iteration markers

    func testIterationMarkerSelectsPersona() {
        XCTAssertEqual(FakeData.value(for: "QBITER1 $user->name"), "John Smith")
        XCTAssertEqual(FakeData.value(for: "QBITER2 $user->email"), "alex@example.com")
    }

    func testPersonasCycleModuloThree() {
        XCTAssertEqual(FakeData.value(for: "QBITER3 $user->name"), "Jane Doe")
        XCTAssertEqual(FakeData.value(for: "QBITER4 $user->name"), "John Smith")
    }

    func testNestedMarkersUseFirst() {
        // Outer loop injects its marker in front of the inner loop's.
        XCTAssertEqual(FakeData.value(for: "QBITER2 QBITER1 $name"), "Alex Rivera")
    }

    func testTitleGetsNumericSuffixOnRepeats() {
        XCTAssertEqual(FakeData.value(for: "$post->title"), "Sample Item")
        XCTAssertEqual(FakeData.value(for: "QBITER1 $post->title"), "Sample Item 2")
        XCTAssertEqual(FakeData.value(for: "QBITER2 $post->title"), "Sample Item 3")
    }

    func testDeterministic() {
        XCTAssertEqual(FakeData.value(for: "$user->email"), FakeData.value(for: "$user->email"))
    }

    // MARK: - Category coverage

    func testMoneyWords() {
        XCTAssertEqual(FakeData.value(for: "$order->total"), "24.00")
        XCTAssertEqual(FakeData.value(for: "$unit_price"), "24.00")
    }

    func testCountWords() {
        XCTAssertEqual(FakeData.value(for: "$post->views"), "42")
    }

    func testStatusAndPlace() {
        XCTAssertEqual(FakeData.value(for: "$order->status"), "Active")
        XCTAssertEqual(FakeData.value(for: "$user->city"), "Portland")
        XCTAssertEqual(FakeData.value(for: "$user->country"), "United States")
    }

    func testDescriptionSentence() {
        XCTAssertEqual(FakeData.value(for: "$post->excerpt"),
                       "A short sample sentence used as stand-in preview text.")
    }

    func testSlugYieldsExampleURL() {
        XCTAssertEqual(FakeData.value(for: "$post->slug"), "example.com/sample")
    }

    // MARK: - Array keys, place chains, bare money (task 12)

    func testLocationChainYieldsPlaceNotPerson() {
        XCTAssertEqual(FakeData.value(for: "$location->location->name"), "Portland")
    }

    func testBareLocationYieldsPlace() {
        XCTAssertEqual(FakeData.value(for: "$location"), "Portland")
    }

    func testUserNameStillYieldsPerson() {
        XCTAssertEqual(FakeData.value(for: "$user->name"), "Jane Doe")
    }

    func testArrayKeysAreSegments() {
        XCTAssertEqual(FakeData.value(for: "abs($analytics['trends']['revenue_growth'])"), "12")
    }

    func testEarningsArrayKeyYieldsBareMoney() {
        XCTAssertEqual(FakeData.value(for: "number_format($analytics['revenue']['total_earnings'] ?? 0, 2)"), "24.00")
    }

    func testRateYieldsBareNumber() {
        XCTAssertEqual(FakeData.value(for: "number_format($analytics['content']['view_to_purchase_rate'] ?? 0, 1)"), "12")
    }

    func testAddressChainWithNameStaysPerson() {
        // An address object's `name` field is a recipient, not a place.
        XCTAssertEqual(FakeData.value(for: "$order->address->name"), "Jane Doe")
    }

    // MARK: - Name resolution by chain context (task 16)

    func testItemNameYieldsItemNotPerson() {
        XCTAssertEqual(FakeData.value(for: "$item['name']"), "Sample Item")
    }

    func testProductChainNameYieldsItem() {
        XCTAssertEqual(FakeData.value(for: "$product->name"), "Sample Item")
    }

    func testRoleWordsArePersonContext() {
        XCTAssertEqual(FakeData.value(for: "$task->assignee->name"), "Jane Doe")
        XCTAssertEqual(FakeData.value(for: "$post->creator->name"), "Jane Doe")
        XCTAssertEqual(FakeData.value(for: "$project->client->name"), "Jane Doe")
    }

    func testUserArrayNameYieldsPerson() {
        XCTAssertEqual(FakeData.value(for: "$user['name']"), "Jane Doe")
    }

    func testCompanyNameYieldsOrg() {
        XCTAssertEqual(FakeData.value(for: "$company->name"), "Acme Corp")
    }

    func testBareCompanyYieldsOrg() {
        XCTAssertEqual(FakeData.value(for: "$company"), "Acme Corp")
    }

    func testBareNameStaysPerson() {
        XCTAssertEqual(FakeData.value(for: "$name"), "Jane Doe")
    }

    func testItemNameCyclesWithIterations() {
        XCTAssertEqual(FakeData.value(for: "QBITER1 $item['name']"), "Sample Item 2")
    }

    func testOrgCyclesPersonas() {
        XCTAssertEqual(FakeData.value(for: "QBITER1 $company->name"), "Globex Ltd")
    }
}
