import Foundation
import Testing
@testable import ThreadLightCore

@Test func basicSearchParsesSlackOperators() throws {
    let result = try SearchParser.parse(.init(text: "\"legal hold\" from:Alex in:general after:2026-01-02 has:file is:edited"))
    #expect(result.fts5Expression?.contains("legal hold") == true)
    #expect(result.filters.sender == "Alex")
    #expect(result.filters.conversation == "general")
    #expect(result.filters.after != nil)
    #expect(result.filters.hasAttachment == true)
    #expect(result.filters.isEdited == true)
}

@Test func advancedSearchCompilesBooleanAndProximity() throws {
    let result = try SearchParser.parse(.init(text: "fraud AND (from:alex OR (\"wire transfer\" NEAR/10 approval))", mode: .advanced))
    let expression = try #require(result.fts5Expression)
    #expect(expression.contains("AND"))
    #expect(expression.contains("sender_name"))
    #expect(expression.contains("NEAR("))
}

@Test func advancedSearchRejectsBooleanGroupInsideProximity() {
    #expect(throws: ThreadLightError.self) {
        _ = try SearchParser.parse(.init(text: "(fraud OR bribery) NEAR/10 approval", mode: .advanced))
    }
}

@Test func advancedSearchParsesQuotedFieldPhrase() throws {
    let result = try SearchParser.parse(.init(text: #"text:"wire transfer" AND from:"Alex Rivera""#, mode: .advanced))
    let expression = try #require(result.fts5Expression)
    #expect(expression.contains(#"text:"wire transfer""#))
    #expect(expression.contains(#"sender_name:"Alex Rivera""#))
}

@Test func basicSearchParsesQuotedOperatorValue() throws {
    let result = try SearchParser.parse(.init(text: #"from:"Alex Rivera" "legal hold""#))
    #expect(result.filters.sender == "Alex Rivera")
    #expect(result.fts5Expression?.contains(#""legal hold""#) == true)
}

@Test func invalidAdvancedSearchFailsClosed() {
    #expect(throws: (any Error).self) {
        _ = try SearchParser.parse(.init(text: "fraud AND (approval", mode: .advanced))
    }
}
