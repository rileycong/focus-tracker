import XCTest
import SwiftUI
@testable import FocusTracker

// NOTE (issue #35 — honest suite pattern): the suite has no view-hosting or
// snapshot dependency, so the ring's COLOR is pinned at the token layer —
// exactly the issue's "token-level assertions if the color is tokenized".
// The views stroke `DesignTokens.focusRing` / `.focusRingCompleted`
// directly (`TimerView`); the break ring's blue is pinned here too so a
// future palette edit cannot silently recolor `BreakView`. Whether the red
// reads calm to the USER is the visual re-test on the rebuilt binary
// (noted on the issue), not a unit assertion.

/// Token-level color assertions for the #35 focus-ring change: the exact
/// documented calm dark-theme red (running), the lighter same-family
/// completion tint (expired/completed), the break ring's pinned blue, and
/// dark-theme legibility (WCAG relative-luminance contrast) for the full
/// arc and the `pausedArcOpacity`-dimmed paused state.
final class DesignTokensTests: XCTestCase {

    func testTaskSelectorTypographyHasStrictSemanticOrdering() {
        XCTAssertEqual(DesignTokens.selectorProjectTitleSize, 20)
        XCTAssertEqual(DesignTokens.selectorStatusTitleSize, 17)
        XCTAssertEqual(DesignTokens.selectorParentTaskTitleSize, 15)
        XCTAssertEqual(DesignTokens.selectorSubtaskTitleSize, 13)
        XCTAssertEqual(DesignTokens.tasksMetadataSize, 12)
        XCTAssertEqual(DesignTokens.tasksChipSize, 11)
        XCTAssertGreaterThan(
            DesignTokens.selectorProjectTitleSize, DesignTokens.selectorStatusTitleSize)
        XCTAssertGreaterThan(
            DesignTokens.selectorStatusTitleSize, DesignTokens.selectorParentTaskTitleSize)
        XCTAssertGreaterThan(
            DesignTokens.selectorParentTaskTitleSize, DesignTokens.selectorSubtaskTitleSize)
        XCTAssertGreaterThan(
            DesignTokens.selectorSubtaskTitleSize, DesignTokens.tasksMetadataSize)
    }

    func testTaskSelectorIndentationHasStrictSemanticOrdering() {
        XCTAssertEqual(DesignTokens.selectorProjectIndent, 0)
        XCTAssertEqual(DesignTokens.selectorStatusIndent, 20)
        XCTAssertEqual(DesignTokens.selectorParentTaskIndent, 48)
        XCTAssertEqual(DesignTokens.selectorSubtaskIndent, 24)
        XCTAssertLessThan(
            DesignTokens.selectorProjectIndent, DesignTokens.selectorStatusIndent)
        XCTAssertLessThan(
            DesignTokens.selectorStatusIndent, DesignTokens.selectorTaskIndent(depth: 0))
        XCTAssertLessThan(
            DesignTokens.selectorTaskIndent(depth: 0),
            DesignTokens.selectorTaskIndent(depth: 1))
        XCTAssertLessThan(
            DesignTokens.selectorTaskIndent(depth: 1),
            DesignTokens.selectorTaskIndent(depth: 2))
        XCTAssertEqual(DesignTokens.selectorTaskIndent(depth: 0), 48)
        XCTAssertEqual(DesignTokens.selectorTaskIndent(depth: 1), 72)
        XCTAssertEqual(DesignTokens.selectorTaskIndent(depth: 2), 96)
    }

    func testTaskSelectorRowsKeepLegibleControlSizing() {
        XCTAssertEqual(DesignTokens.tasksRowVerticalPadding, 10)
        // #40 amendment 2: the intra-group/intra-row rhythm tightened 4 → 3
        // while the approved 10 pt row padding scale stays.
        XCTAssertEqual(DesignTokens.tasksRowSpacing, 3)
        // The new between-status-groups separation: clearly larger than the
        // intra-group rhythm so the group boundary reads as a break.
        XCTAssertEqual(DesignTokens.tasksStatusGroupSpacing, 8)
        XCTAssertGreaterThan(
            DesignTokens.tasksStatusGroupSpacing, DesignTokens.tasksRowSpacing)
        XCTAssertEqual(DesignTokens.tasksStatusDotSize, 9)
        XCTAssertEqual(DesignTokens.tasksChevronIconSize, 10)
        // Issue #51: the hover delete affordance's trash glyph — one step
        // above the chevron so it reads as legible row metadata, still
        // below the 12 pt metadata run.
        XCTAssertEqual(DesignTokens.tasksDeleteIconSize, 11)
        XCTAssertGreaterThan(
            DesignTokens.tasksDeleteIconSize, DesignTokens.tasksChevronIconSize)
        XCTAssertLessThan(
            DesignTokens.tasksDeleteIconSize, DesignTokens.tasksMetadataSize)
    }

    /// #40 amendment 2: the session picker's own tighter indent ladder for
    /// the narrow 460 pt sheet — 0 (project) → 12 (status) → 28 (parent
    /// task) → +16 per subtask depth — pinned with the same strict
    /// project < status < parent < subtask ordering as the Tasks view's
    /// `selector*` ladder above (two ladders, one order).
    func testPickerIndentationHasStrictSemanticOrdering() {
        XCTAssertEqual(DesignTokens.pickerStatusIndent, 12)
        XCTAssertEqual(DesignTokens.pickerParentTaskIndent, 28)
        XCTAssertEqual(DesignTokens.pickerSubtaskIndent, 16)
        XCTAssertGreaterThan(DesignTokens.pickerStatusIndent, 0)
        XCTAssertLessThan(
            DesignTokens.pickerStatusIndent, DesignTokens.pickerTaskIndent(depth: 0))
        XCTAssertLessThan(
            DesignTokens.pickerTaskIndent(depth: 0),
            DesignTokens.pickerTaskIndent(depth: 1))
        XCTAssertLessThan(
            DesignTokens.pickerTaskIndent(depth: 1),
            DesignTokens.pickerTaskIndent(depth: 2))
        XCTAssertEqual(DesignTokens.pickerTaskIndent(depth: 0), 28)
        XCTAssertEqual(DesignTokens.pickerTaskIndent(depth: 1), 44)
        XCTAssertEqual(DesignTokens.pickerTaskIndent(depth: 2), 60)
        // The status → parent step stays wider than the 10 pt row padding,
        // so no row-internal padding can visually invert the order in the
        // narrow sheet either.
        XCTAssertEqual(
            DesignTokens.pickerParentTaskIndent - DesignTokens.pickerStatusIndent, 16)
        XCTAssertGreaterThan(
            DesignTokens.pickerParentTaskIndent - DesignTokens.pickerStatusIndent,
            DesignTokens.tasksRowVerticalPadding)
    }

    /// #40 amendments 3 + 4: the ad-hoc (mode b) form's distribution
    /// rhythm. The dedicated picker→fields break sits on the picker's own
    /// spacingM padding step; the within-fields gap (title ↔ the
    /// category+chips cluster) sits 8 pt above the spacingL scale step
    /// (amendment 4's bump, 20 → 28); the two flexible gaps around the
    /// explanatory footnote share a strictly larger collapse floor — one
    /// calm 4 pt step above the within-fields gap — so even at its floor
    /// the footnote/duration territory breathes more than the field
    /// cluster's internal rhythm and the footnote tracks the lower half of
    /// the fixed 460×500 sheet. (The composition itself — fields →
    /// Spacer → footnote → Spacer, `minHeight` = measured height — is
    /// visual; see the honest-suite note at the top. These tokens are
    /// the pinned part.)
    func testAdHocFormSpacingTokensPinTheDistributionFloors() {
        XCTAssertEqual(DesignTokens.adHocPickerToFieldsSpacing, 14)
        XCTAssertEqual(DesignTokens.adHocPickerToFieldsSpacing, DesignTokens.spacingM)
        XCTAssertEqual(DesignTokens.adHocFormFieldSpacing, 28)
        XCTAssertEqual(DesignTokens.adHocFormSectionSpacing, 32)
        // The within-fields step is the amendment-4 bump above the
        // existing spacingL scale step; the flexible gaps' floor stays
        // exactly one calm 4 pt step above it (see the token docs) and
        // strictly outranks it, so the between-areas breathing never reads
        // tighter than the fields' internal one — not even while the gaps
        // collapse.
        XCTAssertEqual(DesignTokens.adHocFormFieldSpacing, DesignTokens.spacingL + 8)
        XCTAssertEqual(
            DesignTokens.adHocFormSectionSpacing,
            DesignTokens.adHocFormFieldSpacing + 4)
        XCTAssertGreaterThan(
            DesignTokens.adHocFormSectionSpacing, DesignTokens.adHocFormFieldSpacing)
    }

    /// #40 amendment 4: the ad-hoc form's entry scale. The Title/Category
    /// fields render one step above the 13 pt body default (`adHocFieldFont`
    /// = 15, the `.title3` scale) on the approved `.controlSize(.large)`;
    /// the committed-category chips (the private `FlowChips`) scale to
    /// 12 pt with an 11 pt remove glyph so the capsules stay coherent with
    /// the bigger fields, while the #16 forms' chips keep the shared 10 pt
    /// `chipFont`/`chipRemoveIconSize`. The coherence ladder is pinned:
    /// fields outrank their committed chips, and the chips outrank the
    /// shared form chip scale.
    func testAdHocFormEntryTypographyIsOneStepAboveBody() {
        XCTAssertEqual(DesignTokens.adHocFieldFontSize, 15)
        XCTAssertEqual(DesignTokens.adHocChipFontSize, 12)
        XCTAssertEqual(DesignTokens.adHocChipRemoveIconSize, 11)
        // One step above the 13 pt macOS body default (the .title3 scale).
        XCTAssertGreaterThan(DesignTokens.adHocFieldFontSize, 13)
        // Fields > their committed chips > the shared 10 pt form chip scale
        // (the #16 forms' capsules), and the remove glyph grows with them.
        XCTAssertGreaterThan(DesignTokens.adHocFieldFontSize, DesignTokens.adHocChipFontSize)
        XCTAssertGreaterThan(DesignTokens.adHocChipFontSize, 10)
        XCTAssertGreaterThan(
            DesignTokens.adHocChipRemoveIconSize, DesignTokens.chipRemoveIconSize)
    }

    // MARK: - Helpers (sRGB resolution + WCAG contrast)

    /// Resolves a SwiftUI `Color` to its sRGB components — the tokens are
    /// fixed non-adaptive colors and the app forces the dark scheme, so the
    /// authored component values are exactly what renders.
    private func sRGBComponents(of color: Color) -> (r: Double, g: Double, b: Double, a: Double) {
        let resolved = NSColor(color).usingColorSpace(.sRGB)
        XCTAssertNotNil(resolved, "color resolves in sRGB")
        guard let resolved else { return (0, 0, 0, 0) }
        return (
            Double(resolved.redComponent),
            Double(resolved.greenComponent),
            Double(resolved.blueComponent),
            Double(resolved.alphaComponent))
    }

    /// WCAG relative luminance of an sRGB color.
    private func relativeLuminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
        func linearized(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearized(c.r) + 0.7152 * linearized(c.g)
            + 0.0722 * linearized(c.b)
    }

    private func contrastRatio(_ l1: Double, _ l2: Double) -> Double {
        (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    private func contrastRatio(
        _ foreground: (r: Double, g: Double, b: Double),
        _ background: (r: Double, g: Double, b: Double)
    ) -> Double {
        contrastRatio(
            relativeLuminance(foreground), relativeLuminance(background))
    }

    /// The enforced dark background (`DesignTokens.background`), fixed at
    /// `Color(white: 0.12)`.
    private var backgroundComponents: (r: Double, g: Double, b: Double) { (0.12, 0.12, 0.12) }

    // MARK: - Running ring: the documented calm dark-theme red (criterion 1)

    func testFocusRingResolvesToTheDocumentedCalmRed() {
        let c = sRGBComponents(of: DesignTokens.focusRing)
        XCTAssertEqual(c.r, 1.0, accuracy: 0.001)
        XCTAssertEqual(c.g, 0.45, accuracy: 0.001)
        XCTAssertEqual(c.b, 0.42, accuracy: 0.001)
        XCTAssertEqual(c.a, 1.0, accuracy: 0.001)
    }

    func testFocusRingIsRedDominatedAndNotAStatusPaletteReuse() {
        // A red-family hue (red channel dominant), and deliberately not a
        // reuse of the status colors the ring previously rendered with.
        let ring = sRGBComponents(of: DesignTokens.focusRing)
        XCTAssertGreaterThan(ring.r, ring.g)
        XCTAssertGreaterThan(ring.r, ring.b)
        XCTAssertNotEqual(DesignTokens.focusRing, DesignTokens.statusColor(.inProgress))
        XCTAssertNotEqual(DesignTokens.focusRingCompleted, DesignTokens.statusColor(.done))
    }

    // MARK: - Expired/completed state: lighter tint, same red family

    func testCompletedRingIsALighterTintOfTheSameRedFamily() {
        let running = sRGBComponents(of: DesignTokens.focusRing)
        let completed = sRGBComponents(of: DesignTokens.focusRingCompleted)
        // Same warm-red family: the red channel dominates in both states.
        XCTAssertGreaterThan(completed.r, completed.g)
        XCTAssertGreaterThan(completed.r, completed.b)
        // Completion is the LIGHTER family member — every channel at least
        // the running tone, green/blue strictly lighter, so the full expiry
        // circle reads as the settled "done" highlight while staying red.
        XCTAssertGreaterThanOrEqual(completed.r, running.r)
        XCTAssertGreaterThan(completed.g, running.g)
        XCTAssertGreaterThan(completed.b, running.b)
    }

    // MARK: - Break ring stays blue (issue #35 criterion 3)

    func testBreakRingColorsArePinnedUnchanged() {
        // `BreakView` strokes exactly these two status colors; pinned
        // component-exact so this issue (or any later palette edit) cannot
        // silently recolor the break ring away from its blue + green done.
        let inProgress = sRGBComponents(of: DesignTokens.statusColor(.inProgress))
        XCTAssertEqual(inProgress.r, 0.42, accuracy: 0.001)
        XCTAssertEqual(inProgress.g, 0.66, accuracy: 0.001)
        XCTAssertEqual(inProgress.b, 1.0, accuracy: 0.001)
        let done = sRGBComponents(of: DesignTokens.statusColor(.done))
        XCTAssertEqual(done.r, 0.45, accuracy: 0.001)
        XCTAssertEqual(done.g, 0.81, accuracy: 0.001)
        XCTAssertEqual(done.b, 0.56, accuracy: 0.001)
    }

    // MARK: - Dark-theme legibility (incl. the paused dim)

    func testRunningRingIsLegibleOnTheDarkBackground() {
        let ring = sRGBComponents(of: DesignTokens.focusRing)
        let ratio = contrastRatio((ring.r, ring.g, ring.b), backgroundComponents)
        // The 10pt arc clears a text-grade floor on the enforced dark
        // background (the token documents ~5.4:1; the old blue was ~5.9:1).
        XCTAssertGreaterThanOrEqual(ratio, 4.0)
    }

    func testPausedDimKeepsTheRedRingVisible() {
        // Paused composites the arc at `pausedArcOpacity` over the dark
        // background; the dimmed red must stay clearly visible — near
        // parity with the blue it replaced (~2.4:1 there, ≥2.0 pinned).
        let ring = sRGBComponents(of: DesignTokens.focusRing)
        let dimmed = (
            r: ring.r * Double(DesignTokens.pausedArcOpacity)
                + backgroundComponents.r * (1 - Double(DesignTokens.pausedArcOpacity)),
            g: ring.g * Double(DesignTokens.pausedArcOpacity)
                + backgroundComponents.g * (1 - Double(DesignTokens.pausedArcOpacity)),
            b: ring.b * Double(DesignTokens.pausedArcOpacity)
                + backgroundComponents.b * (1 - Double(DesignTokens.pausedArcOpacity)))
        let pausedRatio = contrastRatio(dimmed, backgroundComponents)
        XCTAssertGreaterThanOrEqual(pausedRatio, 2.0)
    }

    func testCompletedRingIsMoreLegibleThanTheRunningArc() {
        // The completed full circle (the expiry state) is the lighter
        // family tint — strictly more legible than the running red, so the
        // expired state is the clearest the ring ever renders.
        let running = sRGBComponents(of: DesignTokens.focusRing)
        let completed = sRGBComponents(of: DesignTokens.focusRingCompleted)
        let runningRatio = contrastRatio((running.r, running.g, running.b), backgroundComponents)
        let completedRatio = contrastRatio(
            (completed.r, completed.g, completed.b), backgroundComponents)
        XCTAssertGreaterThan(completedRatio, runningRatio)
        XCTAssertGreaterThanOrEqual(completedRatio, 6.0)
    }
}
