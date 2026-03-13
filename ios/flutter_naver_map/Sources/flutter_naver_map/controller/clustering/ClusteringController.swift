import NMapsMap

internal class ClusteringController: NMCDefaultClusterMarkerUpdater, NMCThresholdStrategy, NMCTagMergeStrategy, NMCMarkerManager {
    private let naverMapView: NMFMapView!
    private let overlayController: OverlayHandler
    private let messageSender: (_ method: String, _ args: Any) -> Void
    
    init(naverMapView: NMFMapView!, overlayController: OverlayHandler, messageSender: @escaping (_: String, _: Any) -> Void) {
        self.naverMapView = naverMapView
        self.overlayController = overlayController
        self.messageSender = messageSender
    }
    
    private var clusterOptions: NaverMapClusterOptions!
    
    private var clusterer: NMCClusterer<NClusterableMarkerInfo>?
    
    private var clusterableMarkers: [NClusterableMarkerInfo: NClusterableMarker] = [:]
    private var mergedScreenDistanceCacheArray: [Double] = Array(repeating: NMC_DEFAULT_SCREEN_DISTANCE, count: 24) // idx: zoom, distance
    private var suppressRelease = false
    private lazy var clusterMarkerUpdate = ClusterMarkerUpdater(callback: { [weak self] info, marker in
        self?.onClusterMarkerUpdate(info, marker)
    })
    private lazy var clusterableMarkerUpdate = ClusterableMarkerUpdater(callback: { [weak self] info, marker in
        self?.onClusterableMarkerUpdate(info, marker)
    })
    
    func updateClusterOptions(_ options: NaverMapClusterOptions) {
        clusterOptions = options
        cacheScreenDistance(options.mergeStrategy.willMergedScreenDistance)
        rebuildClusterer()
    }
    
    private func cacheScreenDistance(_ willMergedScreenDistance: Dictionary<NRange<Int>, Double>) {
        for i in Int(NMF_MIN_ZOOM)...Int(NMF_MAX_ZOOM) { // 0 ~ 21
            let firstMatchedDistance: Double? = willMergedScreenDistance.first(
                where: { k, v in k.isInRange(i) })?.value
            if let distance = firstMatchedDistance { mergedScreenDistanceCacheArray[i] = distance }
        }
    }
    
    private func buildClusterer() -> NMCClusterer<NClusterableMarkerInfo> {
        let builder = NMCComplexBuilder<NClusterableMarkerInfo>()
        builder.minClusteringZoom = clusterOptions.enableZoomRange.min ?? Int(NMF_MIN_ZOOM)
        builder.maxClusteringZoom = clusterOptions.enableZoomRange.max ?? Int(NMF_MAX_ZOOM)
        builder.maxScreenDistance = clusterOptions.mergeStrategy.maxMergeableScreenDistance
        builder.animationDuration = Double(clusterOptions.animationDuration) * 0.001
        builder.thresholdStrategy = self
        builder.tagMergeStrategy = self
        builder.minIndexingZoom = 0
        builder.maxIndexingZoom = 0
        builder.markerManager = self
        builder.clusterMarkerUpdater = clusterMarkerUpdate
        builder.leafMarkerUpdater = clusterableMarkerUpdate
        return builder.build()
    }

    private func rebuildClusterer() {
        let oldClusterer = clusterer

        let newClusterer = buildClusterer()
        newClusterer.addAll(clusterableMarkers)
        newClusterer.mapView = naverMapView

        suppressRelease = true
        oldClusterer?.mapView = nil
        suppressRelease = false

        clusterer = newClusterer
    }

    func addClusterableMarkerAll(_ markers: [NClusterableMarker]) {
        let newMarkers: [NClusterableMarkerInfo: NClusterableMarker]
        = Dictionary(uniqueKeysWithValues: markers.map { ($0.clusterInfo, $0) })

        // If clusterer not yet initialized, do full build
        guard let currentClusterer = clusterer else {
            clusterableMarkers.removeAll()
            clusterableMarkers.merge(newMarkers, uniquingKeysWith: { $1 })
            rebuildClusterer()
            return
        }

        let newKeys = Set(newMarkers.keys)
        let existingKeys = Set(clusterableMarkers.keys)
        let toRemove = existingKeys.subtracting(newKeys)
        let toAddKeys = newKeys.subtracting(existingKeys)
        let toAdd = newMarkers.filter { toAddKeys.contains($0.key) }
        let sharedKeys = existingKeys.intersection(newKeys)
        var toRecluster: [NClusterableMarkerInfo: NClusterableMarker] = [:]
        var toUpdateVisibleOnly: [NClusterableMarkerInfo: NClusterableMarker] = [:]

        for key in sharedKeys {
            guard let currentMarker = clusterableMarkers[key],
                  let nextMarker = newMarkers[key] else { continue }

            if hasSameMarkerState(currentMarker, nextMarker) {
                continue
            }

            if hasStructuralChange(currentMarker, nextMarker) {
                toRecluster[key] = nextMarker
            } else {
                toUpdateVisibleOnly[key] = nextMarker
            }
        }

        if toRemove.isEmpty &&
            toAdd.isEmpty &&
            toRecluster.isEmpty &&
            toUpdateVisibleOnly.isEmpty {
            return
        }

        for key in toRemove {
            clusterableMarkers.removeValue(forKey: key)
            currentClusterer.remove(key)
        }

        for key in toRecluster.keys {
            clusterableMarkers.removeValue(forKey: key)
            currentClusterer.remove(key)
        }

        if !toAdd.isEmpty {
            clusterableMarkers.merge(toAdd, uniquingKeysWith: { $1 })
            currentClusterer.addAll(toAdd)
        }

        if !toRecluster.isEmpty {
            clusterableMarkers.merge(toRecluster, uniquingKeysWith: { $1 })
            currentClusterer.addAll(toRecluster)
        }

        if !toUpdateVisibleOnly.isEmpty {
            clusterableMarkers.merge(toUpdateVisibleOnly, uniquingKeysWith: { $1 })
            updateVisibleMarkers(toUpdateVisibleOnly)
        }
    }

    func deleteClusterableMarker(_ overlayInfo: NOverlayInfo) {
        let clusterableOverlayInfo = NClusterableMarkerInfo(id: overlayInfo.id, tags: [:], position: NMGLatLng.invalid())
        clusterableMarkers.removeValue(forKey: clusterableOverlayInfo)
        if let currentClusterer = clusterer {
            currentClusterer.remove(clusterableOverlayInfo)
        } else {
            overlayController.deleteOverlay(info: overlayInfo)
        }
    }

    func clearClusterableMarker() {
        clusterableMarkers.removeAll()
        overlayController.clearOverlays(type: .clusterableMarker)
        rebuildClusterer()
    }
    
    private func onClusterMarkerUpdate(_ clusterMarkerInfo: NMCClusterMarkerInfo, _ marker: NMFMarker) {
        guard let info = clusterMarkerInfo.tag as? NClusterInfo else { return }
//        overlayController.saveOverlay(overlay: marker, info: info.markerInfo.messageOverlayInfo)
        marker.hidden = true
        sendClusterMarkerEvent(info: info)
    }
    
    private func sendClusterMarkerEvent(info: NClusterInfo) {
        messageSender("clusterMarkerBuilder", info.toMessageable())
    }

    private func hasSameMarkerState(_ currentMarker: NClusterableMarker, _ nextMarker: NClusterableMarker) -> Bool {
        return !hasStructuralChange(currentMarker, nextMarker)
        && hasSameWrappedMarker(currentMarker.wrappedOverlay, nextMarker.wrappedOverlay)
    }

    private func hasStructuralChange(_ currentMarker: NClusterableMarker, _ nextMarker: NClusterableMarker) -> Bool {
        return currentMarker.clusterInfo.tags != nextMarker.clusterInfo.tags
        || currentMarker.clusterInfo.position.lat != nextMarker.clusterInfo.position.lat
        || currentMarker.clusterInfo.position.lng != nextMarker.clusterInfo.position.lng
    }

    private func hasSameWrappedMarker(_ currentMarker: NMarker, _ nextMarker: NMarker) -> Bool {
        return currentMarker.info == nextMarker.info
        && currentMarker.position.lat == nextMarker.position.lat
        && currentMarker.position.lng == nextMarker.position.lng
        && hasSameOverlayImage(currentMarker.icon, nextMarker.icon)
        && currentMarker.iconTintColor.toInt() == nextMarker.iconTintColor.toInt()
        && currentMarker.alpha == nextMarker.alpha
        && currentMarker.angle == nextMarker.angle
        && currentMarker.anchor.x == nextMarker.anchor.x
        && currentMarker.anchor.y == nextMarker.anchor.y
        && currentMarker.size.width == nextMarker.size.width
        && currentMarker.size.height == nextMarker.size.height
        && hasSameCaption(currentMarker.caption, nextMarker.caption)
        && hasSameCaption(currentMarker.subCaption, nextMarker.subCaption)
        && currentMarker.captionAligns.map { $0.toMessageableString() } == nextMarker.captionAligns.map { $0.toMessageableString() }
        && currentMarker.captionOffset == nextMarker.captionOffset
        && currentMarker.isCaptionPerspectiveEnabled == nextMarker.isCaptionPerspectiveEnabled
        && currentMarker.isIconPerspectiveEnabled == nextMarker.isIconPerspectiveEnabled
        && currentMarker.isFlat == nextMarker.isFlat
        && currentMarker.isForceShowCaption == nextMarker.isForceShowCaption
        && currentMarker.isForceShowIcon == nextMarker.isForceShowIcon
        && currentMarker.isHideCollidedCaptions == nextMarker.isHideCollidedCaptions
        && currentMarker.isHideCollidedMarkers == nextMarker.isHideCollidedMarkers
        && currentMarker.isHideCollidedSymbols == nextMarker.isHideCollidedSymbols
    }

    private func hasSameOverlayImage(_ currentImage: NOverlayImage?, _ nextImage: NOverlayImage?) -> Bool {
        switch (currentImage, nextImage) {
        case (.none, .none):
            return true
        case let (.some(currentImage), .some(nextImage)):
            return currentImage.path == nextImage.path && currentImage.mode == nextImage.mode
        default:
            return false
        }
    }

    private func hasSameCaption(_ currentCaption: NOverlayCaption?, _ nextCaption: NOverlayCaption?) -> Bool {
        switch (currentCaption, nextCaption) {
        case (.none, .none):
            return true
        case let (.some(currentCaption), .some(nextCaption)):
            return currentCaption.text == nextCaption.text
            && currentCaption.textSize == nextCaption.textSize
            && currentCaption.color.toInt() == nextCaption.color.toInt()
            && currentCaption.haloColor.toInt() == nextCaption.haloColor.toInt()
            && currentCaption.minZoom == nextCaption.minZoom
            && currentCaption.maxZoom == nextCaption.maxZoom
            && currentCaption.requestWidth == nextCaption.requestWidth
        default:
            return false
        }
    }

    private func updateVisibleMarkers(_ markers: [NClusterableMarkerInfo: NClusterableMarker]) {
        for (info, clusterableMarker) in markers {
            guard let overlay = overlayController.getOverlay(info: info.messageOverlayInfo) as? NMFMarker else {
                continue
            }
            _ = overlayController.saveOverlayWithAddable(
                creator: clusterableMarker.wrappedOverlay,
                createdOverlay: overlay
            )
        }
    }

    private func onClusterableMarkerUpdate(_ clusterableMarkerInfo: NMCLeafMarkerInfo, _ marker: NMFMarker) {
        marker.iconImage = NMF_MARKER_IMAGE_BLACK
       let nClusterableMarker: NClusterableMarker = clusterableMarkerInfo.tag as! NClusterableMarker
       let nMarker: NMarker = nClusterableMarker.wrappedOverlay
       _ = overlayController.saveOverlayWithAddable(creator: nMarker, createdOverlay: marker)
    }
    
    func getThreshold(_ zoom: Int) -> Double {
        return mergedScreenDistanceCacheArray[zoom]
    }
    
    func mergeTag(_ cluster: NMCCluster) -> NSObject? {
        var mergedTagKey: String? = nil
        var children: [NClusterableMarkerInfo] = []
        
        for node in cluster.children {
            let data = node.tag
            switch data {
            case let data as NClusterableMarker:
                children.append(data.clusterInfo)
            case let data as NClusterInfo:
                if mergedTagKey == nil { mergedTagKey = data.mergedTagKey }
                children.append(contentsOf: data.children)
            default:
                print(data?.description ?? "empty tag")
            }
        }
        
        return NClusterInfo(
            children: children,
            clusterSize: children.count,
            position: cluster.position,
            mergedTagKey: mergedTagKey,
            mergedTag: nil
        )
    }
    
    func retainMarker(_ info: NMCMarkerInfo) -> NMFMarker? {
        let marker = NMFMarker(position: info.position)
        let data = info.tag
        switch data {
//         case let data as NClusterableMarker:
//             let nMarker: NMarker = data.wrappedOverlay
//             _ = overlayController.saveOverlayWithAddable(creator: nMarker, createdOverlay: marker)
        case let data as NClusterInfo:
            overlayController.saveOverlay(overlay: marker, info: data.markerInfo.messageOverlayInfo)
        default: ()
        }
        
        return marker
    }
    
    func releaseMarker(_ info: NMCMarkerInfo, _ marker: NMFMarker) {
        if suppressRelease { return }
        let data = info.tag
        switch data {
        case let data as NClusterableMarker:
            overlayController.deleteOverlay(info: data.info)
        case let data as NClusterInfo:
            overlayController.deleteOverlay(info: data.markerInfo.messageOverlayInfo)
        default:
            return;
        }
    }
    
    func dispose() {
        clusterer?.mapView = nil
        clusterer?.clear()
        clusterer = nil
        clusterableMarkers.removeAll()
    }
    
    deinit {
        dispose()
    }
}

class ClusterMarkerUpdater: NMCDefaultClusterMarkerUpdater {
    let callback: (_ clusterMarkerInfo: NMCClusterMarkerInfo, _ marker: NMFMarker) -> Void
    
    init(callback: @escaping (_: NMCClusterMarkerInfo, _: NMFMarker) -> Void) {
        self.callback = callback
    }
    
    override func updateClusterMarker(_ info: NMCClusterMarkerInfo, _ marker: NMFMarker) {
        callback(info, marker)
    }
}

class ClusterableMarkerUpdater: NMCDefaultLeafMarkerUpdater {
    let callback: (_ clusterableMarkerInfo: NMCLeafMarkerInfo, _ marker: NMFMarker) -> Void
    
    init(callback: @escaping (_: NMCLeafMarkerInfo, _: NMFMarker) -> Void) {
        self.callback = callback
    }
    
    override func updateLeafMarker(_ info: NMCLeafMarkerInfo, _ marker: NMFMarker) {
        super.updateLeafMarker(info, marker)
        callback(info, marker)
    }
}
