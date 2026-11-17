import Foundation
import Testing
@testable import TraceCore

@Test func localizedResourcesFollowPreferredLanguage() {
    #expect(TraceLocalization.text("Network requests", language: "en-US") == "Network requests")
    #expect(TraceLocalization.text("Network requests", language: "zh-CN") == "网络请求")
    #expect(TraceLocalization.text("Network requests", language: "zh-TW") == "网络请求")
    #expect(TraceLocalization.text("Network requests", language: "fr-FR") == "Network requests")
    #expect(TraceLocalization.text("JSON decoding failed", language: "zh-Hans") == "JSON 解码失败")
    #expect(TraceLocalization.text("[REDACTED]", language: "en") == "[REDACTED]")
    #expect(TraceLocalization.text("[REDACTED]", language: "zh-Hans") == "[已隐藏]")
}

@Test func localizedFormatsPreserveValues() {
    for (language, expected) in [("en", "12 requests"), ("zh-Hans", "12 条")] {
        let template = TraceLocalization.text("%@ requests", language: language)
        #expect(String(format: template, "12") == expected)
    }
}
