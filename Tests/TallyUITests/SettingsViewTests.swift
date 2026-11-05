import AppKit
import SwiftUI
import Testing
@testable import TallyUI

@MainActor @Suite struct SettingsViewTokenTests {
    @Test func fineGrainedTokensAreRecognizedByTheirPrefix() {
        #expect(SettingsView.isFineGrained("github_pat_11ABC_xyz"))
        #expect(SettingsView.isFineGrained("  github_pat_11ABC_xyz\n"))
    }

    @Test func classicAndCliTokensAreNotFineGrained() {
        #expect(!SettingsView.isFineGrained("ghp_abc123"))
        #expect(!SettingsView.isFineGrained("gho_abc123"))
        #expect(!SettingsView.isFineGrained(""))
    }

    @Test func theWarningNamesTheFixAndTheTokenKindThatNeedsIt() {
        #expect(SettingsView.fineGrainedWarning.contains("classic token with the `repo` scope"))
        #expect(SettingsView.fineGrainedWarning.contains("Fine-grained"))
    }
}
