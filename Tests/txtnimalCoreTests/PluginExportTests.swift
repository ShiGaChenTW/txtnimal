import XCTest
@testable import txtnimalCore

final class PluginExportTests: XCTestCase {
    private func manifest(capabilities: [PluginCapability]) -> PluginManifest {
        PluginManifest(id: "app.txtnimal.exporter", name: "Exporter", version: "1.0.0",
                       apiVersion: 1, entry: "main.js", capabilities: capabilities)
    }

    private func action(filename: String = "report.md",
                        mimeType: String = "text/markdown",
                        content: String = "# Report\n",
                        destination: PluginExportDestination = .file,
                        taskIDs: [String]? = nil,
                        due: String? = nil) -> PluginAction {
        PluginAction(type: .exportWrite, command: PluginAction.exportWriteCommand,
                     taskIDs: taskIDs, due: due,
                     filename: filename, mimeType: mimeType, content: content, destination: destination)
    }

    func testArtifactJSONRoundTrips() throws {
        let artifact = PluginExportArtifact(filename: "report.md", mimeType: "text/markdown", content: "# Report\n")

        let data = try JSONEncoder().encode(artifact)
        let decoded = try JSONDecoder().decode(PluginExportArtifact.self, from: data)

        XCTAssertEqual(decoded, artifact)
    }

    func testDestinationEnumJSONRoundTrips() throws {
        let data = try JSONEncoder().encode(PluginExportDestination.share)
        let decoded = try JSONDecoder().decode(PluginExportDestination.self, from: data)

        XCTAssertEqual(decoded, .share)
    }

    func testValidateExportActionRejectsMissingCapability() {
        XCTAssertThrowsError(try PluginValidator.validate(exportAction: action(),
                                                          manifest: manifest(capabilities: [.uiPage]))) {
            XCTAssertEqual($0 as? PluginValidationError, .missingCapability)
        }
    }

    func testValidateExportActionRejectsFilenameWithSlash() {
        XCTAssertThrowsError(try PluginValidator.validate(exportAction: action(filename: "reports/out.md"),
                                                          manifest: manifest(capabilities: [.exportWrite]))) {
            XCTAssertEqual($0 as? PluginValidationError, .invalidAction)
        }
    }

    func testValidateExportActionRejectsFilenameWithTraversal() {
        XCTAssertThrowsError(try PluginValidator.validate(exportAction: action(filename: "..report.md"),
                                                          manifest: manifest(capabilities: [.exportWrite]))) {
            XCTAssertEqual($0 as? PluginValidationError, .invalidAction)
        }
    }

    func testValidateExportActionRejectsOversizeContent() {
        let content = String(repeating: "x", count: PluginExportArtifact.maximumContentBytes + 1)

        XCTAssertThrowsError(try PluginValidator.validate(exportAction: action(content: content),
                                                          manifest: manifest(capabilities: [.exportWrite]))) {
            XCTAssertEqual($0 as? PluginValidationError, .invalidAction)
        }
    }

    func testValidateExportActionReturnsValidatedExport() throws {
        let validated = try PluginValidator.validate(exportAction: action(filename: "calendar.ics",
                                                                          mimeType: "text/calendar",
                                                                          content: "BEGIN:VCALENDAR",
                                                                          destination: .share),
                                                     manifest: manifest(capabilities: [.exportWrite]))

        XCTAssertEqual(validated.pluginID, "app.txtnimal.exporter")
        XCTAssertEqual(validated.artifact.filename, "calendar.ics")
        XCTAssertEqual(validated.artifact.mimeType, "text/calendar")
        XCTAssertEqual(validated.artifact.content, "BEGIN:VCALENDAR")
        XCTAssertEqual(validated.destination, .share)
    }

    func testValidateExportActionRejectsSmuggledTaskFields() {
        XCTAssertThrowsError(try PluginValidator.validate(exportAction: action(taskIDs: ["task-1"]),
                                                          manifest: manifest(capabilities: [.exportWrite]))) {
            XCTAssertEqual($0 as? PluginValidationError, .invalidAction)
        }

        XCTAssertThrowsError(try PluginValidator.validate(exportAction: action(due: "2026-07-24"),
                                                          manifest: manifest(capabilities: [.exportWrite]))) {
            XCTAssertEqual($0 as? PluginValidationError, .invalidAction)
        }
    }
}
