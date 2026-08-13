import Foundation

public enum ScopeEvaluator {
    public static func evaluateSourceConsistency(_ memberships: [HoldMembership]) -> ScopeDecision {
        let hashes = Set(memberships.map(\.sourceMessageSHA256).filter { !$0.isEmpty })
        guard hashes.count <= 1 else {
            return .blocked(
                reason: .conflictingSourceRecords,
                detail: "The same Slack message differs across source ZIPs. ThreadLight will not choose one source representation for evidence."
            )
        }
        return .eligible
    }

    public static func evaluate(
        message: EvidenceMessage,
        hold: LegalHold,
        custodian: Custodian?,
        archive: SourceArchive?,
        membership: HoldMembership?
    ) -> ScopeDecision {
        if hold.status == .released {
            return .blocked(reason: .releasedHold, detail: "This hold has been released. ThreadLight blocks search and export.")
        }
        guard hold.status == .active else {
            return .blocked(reason: .holdStatusUnverified, detail: "Slack did not confirm that this hold is active. ThreadLight blocks search and export.")
        }
        guard let archive else {
            return .blocked(reason: .untrustedArchive, detail: "The message has no completed Slack source archive.")
        }
        guard let membership,
              membership.holdID == hold.id,
              membership.sourceArchiveID == archive.id else {
            return .blocked(reason: .ambiguousMembership, detail: "Hold membership cannot be proven from the imported source.")
        }
        if archive.isPerCustodian {
            guard let custodian else {
                return .blocked(reason: .missingCustodian, detail: "No hold member is linked to this legacy source record.")
            }
            guard custodian.isCurrent else {
                return .blocked(reason: .custodianNotCurrent, detail: "The linked hold member is no longer current.")
            }
            guard membership.custodianID == custodian.id else {
                return .blocked(reason: .ambiguousMembership, detail: "Hold membership cannot be proven from the imported source.")
            }
        } else if membership.custodianID != "threadlight:hold-wide" {
            return .blocked(reason: .untrustedArchive, detail: "The hold-wide source marker is invalid.")
        }
        if let start = hold.startAt, message.postedAt < start {
            return .blocked(reason: .outsideDateRange, detail: "The message predates the hold window.")
        }
        if let end = hold.endAt, message.postedAt > end {
            return .blocked(reason: .outsideDateRange, detail: "The message is after the hold window.")
        }
        if hold.restrictions.contains(.onlyDMs), !message.conversationKind.isDirect {
            return .blocked(reason: .conversationRestricted, detail: "This hold covers direct messages only.")
        }
        return .eligible
    }
}
