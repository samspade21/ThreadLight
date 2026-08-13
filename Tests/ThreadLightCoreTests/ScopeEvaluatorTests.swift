import Foundation
import Testing
@testable import ThreadLightCore

@Test func scopeEvaluatorAcceptsProvenPerCustodianMessage() {
    let fixture = ScopeFixture()
    #expect(ScopeEvaluator.evaluate(
        message: fixture.message,
        hold: fixture.hold,
        custodian: fixture.custodian,
        archive: fixture.archive,
        membership: fixture.membership
    ).canExport)
}

@Test func scopeEvaluatorBlocksReleasedAndWrongConversation() {
    var fixture = ScopeFixture()
    fixture.hold.status = .released
    #expect(!ScopeEvaluator.evaluate(message: fixture.message, hold: fixture.hold, custodian: fixture.custodian, archive: fixture.archive, membership: fixture.membership).canExport)
    fixture.hold.status = .active
    fixture.hold.restrictions = [.onlyDMs]
    #expect(!ScopeEvaluator.evaluate(message: fixture.message, hold: fixture.hold, custodian: fixture.custodian, archive: fixture.archive, membership: fixture.membership).canExport)
}

@Test func scopeEvaluatorBlocksUnknownHoldStatusDistinctly() {
    var fixture = ScopeFixture()
    fixture.hold.status = .unknown
    #expect(reason(ScopeEvaluator.evaluate(
        message: fixture.message,
        hold: fixture.hold,
        custodian: fixture.custodian,
        archive: fixture.archive,
        membership: fixture.membership
    )) == .holdStatusUnverified)
}

@Test func scopeEvaluatorBlocksConflictingSourceMessageHashes() {
    let sourceID = UUID()
    let memberships = [
        HoldMembership(holdID: "H1", custodianID: "U1", messageID: "M1", sourceArchiveID: sourceID, sourceMessageSHA256: "aaa"),
        HoldMembership(holdID: "H1", custodianID: "U2", messageID: "M1", sourceArchiveID: UUID(), sourceMessageSHA256: "bbb"),
    ]
    #expect(reason(ScopeEvaluator.evaluateSourceConsistency(memberships)) == .conflictingSourceRecords)
}

@Test func scopeEvaluatorReturnsStableReasonForEveryProvenanceFailure() {
    var fixture = ScopeFixture()
    #expect(reason(ScopeEvaluator.evaluate(
        message: fixture.message, hold: fixture.hold, custodian: nil,
        archive: fixture.archive, membership: fixture.membership
    )) == .missingCustodian)

    fixture.custodian.isCurrent = false
    #expect(reason(ScopeEvaluator.evaluate(
        message: fixture.message, hold: fixture.hold, custodian: fixture.custodian,
        archive: fixture.archive, membership: fixture.membership
    )) == .custodianNotCurrent)
    fixture.custodian.isCurrent = true

    fixture.archive = SourceArchive(
        holdID: fixture.hold.id,
        custodianID: fixture.custodian.id,
        originalFilename: "whole-org.zip",
        sha256: "whole-org",
        coverageStart: nil,
        coverageEnd: nil,
        operatorBinding: "Reviewer",
        isPerCustodian: false
    )
    #expect(reason(ScopeEvaluator.evaluate(
        message: fixture.message, hold: fixture.hold, custodian: fixture.custodian,
        archive: fixture.archive, membership: fixture.membership
    )) == .ambiguousMembership)

    fixture = ScopeFixture()
    let wrongMembership = HoldMembership(
        holdID: fixture.hold.id,
        custodianID: "someone-else",
        messageID: fixture.message.id,
        sourceArchiveID: fixture.archive.id
    )
    #expect(reason(ScopeEvaluator.evaluate(
        message: fixture.message, hold: fixture.hold, custodian: fixture.custodian,
        archive: fixture.archive, membership: wrongMembership
    )) == .ambiguousMembership)

    fixture.hold.startAt = fixture.message.postedAt.addingTimeInterval(1)
    #expect(reason(ScopeEvaluator.evaluate(
        message: fixture.message, hold: fixture.hold, custodian: fixture.custodian,
        archive: fixture.archive, membership: fixture.membership
    )) == .outsideDateRange)
}

private func reason(_ decision: ScopeDecision) -> ScopeBlockReason? {
    guard case let .blocked(reason, _) = decision else { return nil }
    return reason
}

private struct ScopeFixture {
    var hold = LegalHold(id: "H1", organizationID: "E1", name: "Case", status: .active, createdAt: .now, updatedAt: .now)
    var custodian = Custodian(id: "U1", holdID: "H1", displayName: "Alex")
    var archive = SourceArchive(holdID: "H1", custodianID: "U1", originalFilename: "export.zip", sha256: "abc", coverageStart: nil, coverageEnd: nil, operatorBinding: "Reviewer", isPerCustodian: true)
    var message = EvidenceMessage(id: "M1", conversationID: "C1", conversationName: "general", conversationKind: .publicChannel, threadID: "M1", senderID: "U1", senderName: "Alex", text: "hello", postedAt: .now)
    var membership: HoldMembership

    init() {
        membership = .init(holdID: "H1", custodianID: "U1", messageID: "M1", sourceArchiveID: archive.id)
    }
}
