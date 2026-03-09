import NMapsMap

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
        guard let image = UIImage(contentsOfFile: path),
              let pngData = image.pngData(),
              let scaledImage = UIImage(data: pngData, scale: DisplayUtil.scale) else {
            return NMF_MARKER_IMAGE_BLACK
        }
        return NMFOverlayImage(image: scaledImage)
    }
    
    private func makeOverlayImageWithAssetPath() -> NMFOverlayImage {
        let key = SwiftFlutterNaverMapPlugin.getAssets(path: path)
        let assetPath = Bundle.main.path(forResource: key, ofType: nil) ?? ""
        let image = UIImage(contentsOfFile: assetPath)
        let scaledImage = UIImage(data: image!.pngData()!, scale: DisplayUtil.scale)
        let overlayImg = NMFOverlayImage(image: scaledImage!, reuseIdentifier: assetPath)
        return overlayImg
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
