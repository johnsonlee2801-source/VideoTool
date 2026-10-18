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
