import Foundation
import Vision

/// Labels what an image shows.
protocol ImageTagger {
    /// Tags with confidences in 0...1, best first. Empty if nothing is recognised.
    func tags(forImageAt url: URL) -> [(String, Double)]
}

/// On-device scene classification with Apple's Vision framework: nothing leaves the Mac.
final class VisionTagger: ImageTagger {
    func tags(forImageAt url: URL) -> [(String, Double)] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let request = VNClassifyImageRequest()
        do {
            try VNImageRequestHandler(url: url).perform([request])
        } catch {
            return []
        }
        let observations = (request.results ?? []).map { ($0.identifier, $0.confidence) }
        return TagVocabulary.select(observations)
    }
}

/// Turns Vision's English identifiers into a short list of Chinese tags.
enum TagVocabulary {
    static let minConfidence: Float = 0.3
    static let maxTags = 5

    /// Labels that describe almost every image and help nobody find a video.
    static let ignored: Set<String> = ["structure", "material", "textile", "liquid", "water_body", "conveyance",
                                       "machine", "device", "consumer_electronics", "screenshot", "document"]

    static let chinese: [String: String] = [
        "people": "人物", "adult": "人物", "child": "儿童", "baby": "婴儿", "crowd": "人群", "portrait": "人像",
        "dog": "狗", "cat": "猫", "animal": "动物", "bird": "鸟", "fish": "鱼", "horse": "马",
        "outdoor": "户外", "indoor": "室内", "sky": "天空", "cloudy": "天空", "sunset_sunrise": "日出日落",
        "night_sky": "夜景", "tree": "树木", "plant": "植物", "flower": "花", "grass": "草地", "forest": "森林",
        "mountain": "山", "beach": "海滩", "sea": "海", "ocean": "海", "lake": "湖", "river": "河流", "snow": "雪",
        "city": "城市", "street": "街道", "building": "建筑", "house": "房屋", "room": "室内", "kitchen": "厨房",
        "food": "美食", "drink": "饮品", "car": "汽车", "vehicle": "交通工具", "bicycle": "自行车", "airplane": "飞机",
        "boat": "船", "train": "火车", "sport": "运动", "ball": "球类", "stadium": "体育场", "concert": "演出",
        "stage": "舞台", "music": "音乐", "musical_instrument": "乐器", "screen": "屏幕", "text": "文字",
        "cartoon": "动画", "illustrations": "插画", "art": "艺术", "games": "游戏", "toy": "玩具",
        "wedding": "婚礼", "party": "聚会", "celebration": "庆祝", "fireworks": "烟花", "night": "夜晚",
    ]

    static func localized(_ identifier: String) -> String {
        chinese[identifier] ?? identifier.replacingOccurrences(of: "_", with: " ")
    }

    static func select(_ observations: [(String, Float)]) -> [(String, Double)] {
        var best: [String: Double] = [:]
        for (id, confidence) in observations where confidence >= minConfidence && !ignored.contains(id) {
            let tag = localized(id)
            best[tag] = max(best[tag] ?? 0, Double(confidence))
        }
        return best.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(maxTags).map { ($0.key, $0.value) }
    }
}
