import Testing
@testable import VideoTool

@Suite struct TimeFormattingTests {
    @Test func underAnHour() {
        #expect(TimeFormatting.string(0) == "0:00")
        #expect(TimeFormatting.string(5) == "0:05")
        #expect(TimeFormatting.string(65) == "1:05")
        #expect(TimeFormatting.string(3599.9) == "59:59")
    }
    @Test func hours() {
        #expect(TimeFormatting.string(3600) == "1:00:00")
        #expect(TimeFormatting.string(3661) == "1:01:01")
        #expect(TimeFormatting.string(36000) == "10:00:00")
    }
    @Test func garbage() {
        #expect(TimeFormatting.string(-3) == "0:00")
        #expect(TimeFormatting.string(.nan) == "0:00")
        #expect(TimeFormatting.string(.infinity) == "0:00")
    }

    @Test func hugeFiniteValuesDoNotTrap() {
        #expect(TimeFormatting.string(1e20) == "99999:59:59")
        #expect(TimeFormatting.string(Double.greatestFiniteMagnitude) == "99999:59:59")
    }
}

// Full-codebase audit 2026-10-20 (batch 11).
struct TimeParseAuditTests {
    @Test("TF20 absurd typed times are rejected, and a non-finite range is never exported")
    func overflow() {
        #expect(TimeFormatting.parse("1E308:00") == nil)
        #expect(TimeFormatting.parse("99999999999") == nil)
        #expect(ClipRange(start: .nan, end: 5).problem(duration: 0, format: .gif) != nil)
        #expect(ClipRange(start: 0, end: .infinity).problem(duration: 0, format: .video) != nil)
    }
}
