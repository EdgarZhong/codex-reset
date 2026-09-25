import Foundation

/// 轻量本地化：返回中/英文文案
/// 系统首选语言以 zh 开头时用中文，否则用英文。
func L(_ zh: String, _ en: String) -> String {
    let isZH = Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false
    return isZH ? zh : en
}
