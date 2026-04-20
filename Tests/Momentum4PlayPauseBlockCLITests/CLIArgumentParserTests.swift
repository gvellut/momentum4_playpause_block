@testable import Momentum4PlayPauseBlockCLI
import Momentum4PlayPauseBlockCommon
import Testing

struct CLIArgumentParserTests {
    private let parser = CLIArgumentParser()

    @Test
    func defaultsToAnyHID() throws {
        let parsed = try parser.parse([])

        #expect(parsed.allowedForwardSourceMode == .anyHID)
        #expect(parsed.allowedForwardSourceProductName.isEmpty)
    }

    @Test
    func parsesSpecificProductNameMode() throws {
        let parsed = try parser.parse([
            "--forward-source", "specific-product-name", "--product-name", "Keychron K1 Pro",
        ])

        #expect(parsed.allowedForwardSourceMode == .specificProductName)
        #expect(parsed.allowedForwardSourceProductName == "Keychron K1 Pro")
    }

    @Test
    func parsesAnyKeyboardMode() throws {
        let parsed = try parser.parse(["--forward-source=any-keyboard"])

        #expect(parsed.allowedForwardSourceMode == .anyKeyboard)
        #expect(parsed.allowedForwardSourceProductName.isEmpty)
    }

    @Test
    func rejectsSpecificProductNameWithoutProductName() {
        #expect(throws: CLIArgumentParserError.specificProductNameRequiresValue) {
            try parser.parse(["--forward-source", "specific-product-name"])
        }
    }

    @Test
    func rejectsProductNameWithoutSpecificMode() {
        #expect(throws: CLIArgumentParserError.productNameRequiresSpecificSourceMode) {
            try parser.parse(["--product-name", "Keychron K1 Pro"])
        }
    }

    @Test
    func supportsHelpFlag() {
        #expect(throws: CLIArgumentParserError.helpRequested) {
            try parser.parse(["--help"])
        }
    }

    @Test
    func helpTextDocumentsAppleMusicLimitation() {
        let helpText = CLIUsage.helpText(executableName: "tool")

        #expect(helpText.contains("Apple Music-only"))
        #expect(helpText.contains("--forward-source"))
    }
}
