import AppKit
import XCTest
@testable import AIUsageMonitor

/// Deterministic, offscreen (non-focus-stealing) evidence for the menu-bar status
/// item and its right-click context menu. The behavioural assertions always run as
/// part of the suite so they fail if the real gauge angle, band colours, critical
/// capsule, or menu order regress. The labelled evidence files are only written when
/// `AI_USAGE_MONITOR_EVIDENCE_DIR` is set (evidence-capture mode), keeping normal test
/// runs from touching the working tree.
@MainActor
final class StatusItemEvidenceTests: XCTestCase {
    private struct Sample {
        var utilization: Double
        var expectedBand: UsageStatusBand
        var expectsCapsule: Bool
    }

    private let samples: [Sample] = [
        Sample(utilization: 15, expectedBand: .normal, expectsCapsule: false),
        Sample(utilization: 45, expectedBand: .normal, expectsCapsule: false),
        Sample(utilization: 68, expectedBand: .normal, expectsCapsule: false),
        Sample(utilization: 72, expectedBand: .warning, expectsCapsule: false),
        Sample(utilization: 85, expectedBand: .warning, expectsCapsule: false),
        Sample(utilization: 90, expectedBand: .critical, expectsCapsule: true),
        Sample(utilization: 96, expectedBand: .critical, expectsCapsule: true)
    ]

    // MARK: - Status item bands + gauge angle

    func testStatusItemBandsGaugeAnglesAndCriticalCapsuleTrackUtilization() throws {
        var previousAngle = -Double.greatestFiniteMagnitude

        for sample in samples {
            let presentation = UsagePresentation.statusItem(for: singleMeterSnapshot(utilization: sample.utilization))
            let angle = UsagePresentation.needleAngleDegrees(for: sample.utilization)

            XCTAssertEqual(presentation.band, sample.expectedBand, "Band mismatch at \(sample.utilization)%")
            XCTAssertEqual(
                presentation.showsCriticalCapsule,
                sample.expectsCapsule,
                "Critical capsule mismatch at \(sample.utilization)%"
            )
            XCTAssertEqual(
                presentation.textColor,
                expectedTextColor(for: sample.expectedBand),
                "Percentage colour mismatch at \(sample.utilization)%"
            )
            XCTAssertGreaterThan(angle, previousAngle, "Needle angle must increase with utilization at \(sample.utilization)%")
            previousAngle = angle
        }

        // No-data presentation is monochrome with no gauge value and no capsule.
        let noData = UsagePresentation.statusItem(for: UsageMonitorFixtures.noDataSnapshot)
        XCTAssertEqual(noData.percentText, "--%")
        XCTAssertNil(noData.utilization)
        XCTAssertNil(noData.textColor)
        XCTAssertFalse(noData.showsCriticalCapsule)

        try writeStatusItemEvidenceIfRequested()
    }

    // MARK: - Context menu order + shortcuts

    func testContextMenuEvidenceDumpMatchesCanonicalOrder() throws {
        let expectedOrder = [
            "Refresh Now",
            "Open AI Usage…",
            "separator",
            "Pause Alerts for 1 Hour",
            "Launch at Login",
            "separator",
            "Quit AI Usage"
        ]

        for launchAtLogin in [true, false] {
            let menu = StatusContextMenuFactory.makeMenu(target: nil, launchAtLogin: launchAtLogin)
            XCTAssertEqual(
                menu.items.map { $0.isSeparatorItem ? "separator" : $0.title },
                expectedOrder,
                "Context menu order regressed (launchAtLogin=\(launchAtLogin))"
            )
            XCTAssertEqual(menu.items[0].keyEquivalent, "r")
            XCTAssertEqual(menu.items[0].keyEquivalentModifierMask, [.command])
            XCTAssertEqual(menu.items[6].keyEquivalent, "q")
            XCTAssertEqual(menu.items[6].keyEquivalentModifierMask, [.command])
            XCTAssertEqual(menu.items[4].state, launchAtLogin ? .on : .off)
        }

        try writeContextMenuEvidenceIfRequested()
    }

    // MARK: - Evidence writers

    private func writeStatusItemEvidenceIfRequested() throws {
        guard let directory = evidenceSubdirectory(named: "status-item") else {
            return
        }

        guard let bitmap = renderStatusItemComposite() else {
            XCTFail("Unable to render status-item composite bitmap")
            return
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Unable to encode status-item composite PNG")
            return
        }

        let imageURL = directory.appendingPathComponent("status-item-bands.png")
        try data.write(to: imageURL, options: .atomic)

        var lines: [String] = [
            "artifact: status-item-bands",
            "pixels: \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)",
            "warning_lower_bound: \(Int(UsageStatusBand.warningLowerBound))",
            "critical_lower_bound: \(Int(UsageStatusBand.criticalLowerBound))"
        ]
        for sample in samples {
            let presentation = UsagePresentation.statusItem(for: singleMeterSnapshot(utilization: sample.utilization))
            let angle = UsagePresentation.needleAngleDegrees(for: sample.utilization)
            lines.append(
                "row: \(Int(sample.utilization))% band=\(presentation.band.rawValue) "
                    + "needle_angle_deg=\(String(format: "%.1f", angle)) "
                    + "critical_capsule=\(presentation.showsCriticalCapsule)"
            )
        }
        lines.append("row: no-data band=normal needle_angle_deg=none critical_capsule=false")
        lines.append("secret_free_evidence: true")
        try (lines.joined(separator: "\n") + "\n")
            .write(to: directory.appendingPathComponent("status-item-bands.txt"), atomically: true, encoding: .utf8)
    }

    private func writeContextMenuEvidenceIfRequested() throws {
        guard let directory = evidenceSubdirectory(named: "context-menu") else {
            return
        }

        var lines: [String] = ["artifact: context-menu-order"]
        for launchAtLogin in [true, false] {
            lines.append("")
            lines.append("launch_at_login: \(launchAtLogin)")
            let menu = StatusContextMenuFactory.makeMenu(target: nil, launchAtLogin: launchAtLogin)
            for (index, item) in menu.items.enumerated() {
                if item.isSeparatorItem {
                    lines.append("  [\(index)] ----- separator -----")
                    continue
                }
                let shortcut = item.keyEquivalent.isEmpty
                    ? "-"
                    : "Command-\(item.keyEquivalent.uppercased())"
                let checkmark: String
                switch item.state {
                case .on: checkmark = "checked"
                case .off: checkmark = "unchecked"
                default: checkmark = "mixed"
                }
                lines.append("  [\(index)] \(item.title) | key=\(shortcut) | state=\(checkmark) | enabled=\(item.isEnabled)")
            }
        }
        lines.append("")
        lines.append("secret_free_evidence: true")
        try (lines.joined(separator: "\n") + "\n")
            .write(to: directory.appendingPathComponent("context-menu-order.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: - Rendering

    private func renderStatusItemComposite() -> NSBitmapImageRep? {
        let width = Int(UsagePopoverMetrics.contentWidth * 2)
        let height = Int(UsagePopoverMetrics.contentHeight * 2)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        bitmap.size = NSSize(width: UsagePopoverMetrics.contentWidth, height: UsagePopoverMetrics.contentHeight)

        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        let canvas = NSRect(x: 0, y: 0, width: UsagePopoverMetrics.contentWidth, height: UsagePopoverMetrics.contentHeight)
        UsagePalette.warmCharcoal.deviceRGBColor.setFill()
        canvas.fill()

        let rows = samples.count + 1
        let rowHeight = canvas.height / CGFloat(rows)

        for (index, sample) in samples.enumerated() {
            let presentation = UsagePresentation.statusItem(for: singleMeterSnapshot(utilization: sample.utilization))
            let angle = UsagePresentation.needleAngleDegrees(for: sample.utilization)
            let top = canvas.height - CGFloat(index + 1) * rowHeight
            drawRow(
                rect: NSRect(x: 0, y: top, width: canvas.width, height: rowHeight),
                label: "\(Int(sample.utilization))%  \(sample.expectedBand.rawValue)  \(String(format: "%.0f", angle))°",
                presentation: presentation
            )
        }

        let noData = UsagePresentation.statusItem(for: UsageMonitorFixtures.noDataSnapshot)
        drawRow(
            rect: NSRect(x: 0, y: 0, width: canvas.width, height: rowHeight),
            label: "no data  \(noData.percentText)",
            presentation: noData
        )

        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    private func drawRow(rect: NSRect, label: String, presentation: StatusItemPresentation) {
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: UsagePalette.primaryText.deviceRGBColor
        ]
        NSAttributedString(string: label, attributes: labelAttributes)
            .draw(at: NSPoint(x: 16, y: rect.midY - 8))

        // Faithful status-item chip: the critical capsule image, or the template glyph tinted the
        // way the menu bar tints it plus the percentage in its band colour.
        let chipOrigin = NSPoint(x: 150, y: rect.midY - 10)
        if presentation.showsCriticalCapsule, let utilization = presentation.utilization {
            let capsule = StatusItemGaugeRenderer.criticalCapsuleImage(utilization: utilization, text: presentation.percentText)
            capsule.draw(in: NSRect(origin: chipOrigin, size: capsule.size))
        } else {
            let glyph = tinted(StatusItemGaugeRenderer.glyphImage(utilization: presentation.utilization), color: UsagePalette.primaryText)
            glyph.draw(in: NSRect(origin: NSPoint(x: chipOrigin.x, y: chipOrigin.y + 2), size: glyph.size))
            NSAttributedString(
                string: presentation.percentText,
                attributes: [
                    .font: StatusItemGaugeRenderer.font,
                    .foregroundColor: (presentation.textColor ?? UsagePalette.primaryText).deviceRGBColor
                ]
            ).draw(at: NSPoint(x: chipOrigin.x + 20, y: chipOrigin.y + 2))
        }

        // Enlarged gauge to make the needle angle difference obvious.
        let enlarged = tinted(StatusItemGaugeRenderer.glyphImage(utilization: presentation.utilization), color: UsagePalette.primaryText)
        enlarged.draw(in: NSRect(x: 240, y: rect.midY - 22, width: 44, height: 44))
    }

    private func tinted(_ template: NSImage, color: NSColor) -> NSImage {
        NSImage(size: template.size, flipped: false) { rect in
            template.draw(in: rect)
            color.deviceRGBColor.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    // MARK: - Helpers

    private func singleMeterSnapshot(utilization: Double) -> CombinedUsageSnapshot {
        let capturedAt = UsageMonitorFixtures.baseDate
        return CombinedUsageSnapshot(
            capturedAt: capturedAt,
            providers: [
                ProviderUsageSnapshot(
                    provider: .claude,
                    meters: [
                        UsageMeterSnapshot(
                            kind: .claudeWeekAll,
                            // Callers only pass fixed, in-range (0...100) sample values.
                            utilization: try! UtilizationPercentage(utilization),
                            resetAt: capturedAt.addingTimeInterval(UsageMonitorFixtures.oneDay)
                        )
                    ],
                    health: .fresh(checkedAt: capturedAt)
                ),
                ProviderUsageSnapshot(provider: .codex, meters: [], health: .noData(checkedAt: capturedAt))
            ]
        )
    }

    private func expectedTextColor(for band: UsageStatusBand) -> NSColor? {
        switch band {
        case .normal:
            return nil
        case .warning:
            return UsagePalette.statusWarning
        case .critical:
            return .white
        }
    }

    /// Resolves the evidence root only when explicitly requested (evidence-capture
    /// mode), so ordinary suite runs never touch the working tree. Two gates are
    /// supported: an `AI_USAGE_MONITOR_EVIDENCE_DIR` environment override, or a
    /// sentinel file next to the canonical `.apm` evidence tree (reliable because
    /// `xcodebuild` does not forward environment variables into the macOS unit-test
    /// host process).
    private func evidenceRoot() -> URL? {
        if let root = ProcessInfo.processInfo.environment["AI_USAGE_MONITOR_EVIDENCE_DIR"],
           !root.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: root)
        }

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AIUsageMonitorTests
            .deletingLastPathComponent() // repository root
        let sentinel = repoRoot.appendingPathComponent(".apm/.capture-status-item-evidence")
        guard FileManager.default.fileExists(atPath: sentinel.path) else {
            return nil
        }
        return repoRoot.appendingPathComponent(".apm/evidence/stage-04/task-04-01")
    }

    private func evidenceSubdirectory(named name: String) -> URL? {
        guard let root = evidenceRoot() else {
            return nil
        }
        let directory = root.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
