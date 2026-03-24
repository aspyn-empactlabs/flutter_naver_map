import NMapsMap
import UIKit

internal struct NOverlayImage {
    let path: String
    let mode: NOverlayImageMode

    var overlayImage: NMFOverlayImage {
        switch mode {
        case .file, .temp, .widget: return makeOverlayImageWithPath()
        case .asset: return makeOverlayImageWithAssetPath()
        }
    }

    private func makeOverlayImageWithPath() -> NMFOverlayImage {
        guard
            let image = UIImage(contentsOfFile: path),
            let pngData = image.pngData(),
            let scaledImage = UIImage(data: pngData, scale: DisplayUtil.scale)
        else {
            assertionFailure("Failed to load overlay image at path: \(path)")
            return NMFOverlayImage(image: Self.makeFallbackImage())
        }
        return NMFOverlayImage(image: scaledImage)
    }
    
    private func makeOverlayImageWithAssetPath() -> NMFOverlayImage {
        let key = SwiftFlutterNaverMapPlugin.getAssets(path: path)
        let assetPath = Bundle.main.path(forResource: key, ofType: nil) ?? ""
        guard
            let image = UIImage(contentsOfFile: assetPath),
            let pngData = image.pngData(),
            let scaledImage = UIImage(data: pngData, scale: DisplayUtil.scale)
        else {
            assertionFailure("Failed to load overlay asset at path: \(assetPath)")
            return NMFOverlayImage(image: Self.makeFallbackImage())
        }
        return NMFOverlayImage(image: scaledImage, reuseIdentifier: assetPath)
    }

    private static func makeFallbackImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        return renderer.image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    func toMessageable() -> Dictionary<String, Any> {
        [
            "path": path,
            "mode": mode.rawValue
        ]
    }

    static func fromMessageable(_ v: Any) -> NOverlayImage {
        let d = asDict(v)
        return NOverlayImage(
                path: asString(d["path"]!),
                mode: NOverlayImageMode(rawValue: asString(d["mode"]!))!
        )
    }

    static let none = NOverlayImage(path: "", mode: .temp)
}
