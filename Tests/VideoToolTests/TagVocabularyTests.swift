import Testing
@testable import VideoTool

@Suite struct TagVocabularyTests {
    @Test("V1 keeps confident labels, highest first, at most 5") func select() {
        let obs: [(String, Float)] = [("dog", 0.9), ("outdoor", 0.5), ("grass", 0.31), ("cat", 0.29),
                                      ("sky", 0.6), ("tree", 0.7), ("people", 0.8), ("car", 0.4)]
        let picked = TagVocabulary.select(obs)
        #expect(picked.map(\.0) == ["狗", "人物", "树木", "天空", "户外"])
        #expect(picked.count == TagVocabulary.maxTags)
        #expect(picked.allSatisfy { $0.1 >= Double(TagVocabulary.minConfidence) })
    }

    @Test("V2 labels without a Chinese name keep Vision's identifier, made readable") func passthrough() {
        #expect(TagVocabulary.localized("dog") == "狗")
        #expect(TagVocabulary.localized("hot_air_balloon") == "hot air balloon")
    }

    @Test("V3 two labels mapping to the same Chinese tag are merged, keeping the higher confidence") func merge() {
        let picked = TagVocabulary.select([("people", 0.5), ("adult", 0.8)])
        #expect(picked.map(\.0) == ["人物"])
        #expect(picked.first?.1 == Double(Float(0.8)))
    }

    @Test("V4 overly generic labels are dropped") func generic() {
        #expect(TagVocabulary.select([("structure", 0.95), ("material", 0.9), ("dog", 0.5)]).map(\.0) == ["狗"])
    }
}
