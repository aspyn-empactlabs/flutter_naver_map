package dev.note11.flutter_naver_map.flutter_naver_map.controller.clustering

import android.os.Handler
import android.os.Looper
import android.util.Log
import com.naver.maps.geometry.LatLng
import com.naver.maps.map.NaverMap
import com.naver.maps.map.NaverMap.MAXIMUM_ZOOM
import com.naver.maps.map.NaverMap.MINIMUM_ZOOM
import com.naver.maps.map.clustering.*
import com.naver.maps.map.clustering.Clusterer.ComplexBuilder
import com.naver.maps.map.clustering.Clusterer.DEFAULT_SCREEN_DISTANCE
import com.naver.maps.map.overlay.Marker
import com.naver.maps.map.overlay.Overlay
import com.naver.maps.map.util.MarkerIcons
import dev.note11.flutter_naver_map.flutter_naver_map.controller.overlay.OverlayHandler
import dev.note11.flutter_naver_map.flutter_naver_map.model.base.NRange
import dev.note11.flutter_naver_map.flutter_naver_map.model.enum.NOverlayType
import dev.note11.flutter_naver_map.flutter_naver_map.model.map.info.NClusterableMarkerInfo
import dev.note11.flutter_naver_map.flutter_naver_map.model.map.info.NOverlayInfo
import dev.note11.flutter_naver_map.flutter_naver_map.model.map.overlay.clustering.NaverMapClusterOptions
import dev.note11.flutter_naver_map.flutter_naver_map.model.map.overlay.overlay.NClusterInfo
import dev.note11.flutter_naver_map.flutter_naver_map.model.map.overlay.overlay.NClusterableMarker

internal class ClusteringController(
    private val naverMap: NaverMap,
    private val overlayController: OverlayHandler,
    private val messageSender: (method: String, args: Any) -> Unit,
    private val viewInvalidator: () -> Unit,
) : MarkerManager {
    private lateinit var clusterOptions: NaverMapClusterOptions

    private lateinit var clusterer: Clusterer<NClusterableMarkerInfo>

    private val clusterableMarkers = mutableMapOf<NClusterableMarkerInfo, NClusterableMarker>()
    private val mergedScreenDistanceCacheArray = DoubleArray(24) // idx: zoom, distance
    private var suppressRelease = false
    private var isRefreshSuspended = false
    private var suspendedClusterOverlays: Map<NOverlayInfo, Overlay> = emptyMap()

    private val nowHandler: Handler by lazy { Handler(Looper.getMainLooper()) }
    private var nowViewInvalidationRunnable: Runnable? = null
    private var suspendedOverlayPruneRunnable: Runnable? = null
    private var afterAnimationInvalidateDelay: Long = 80L
    private var lastObservedCameraZoom: Double? = null
    private var pendingPruneOverlays: Map<NOverlayInfo, Overlay> = emptyMap()

    // first caller (change the running in instance init time)
    fun updateClusterOptions(options: NaverMapClusterOptions) {
        clusterOptions = options
        cacheScreenDistance(options.mergeStrategy.willMergedScreenDistance)
        updateAfterAnimationInvalidateDelay(options.animationDuration)
        if (isRefreshSuspended) {
            return
        }
        rebuildClusterer()
    }

    fun onCameraPositionChanged(zoom: Double) {
        val previousZoom = lastObservedCameraZoom
        lastObservedCameraZoom = zoom

        if (!::clusterOptions.isInitialized ||
            !clusterOptions.deferRefreshOnCameraZoomUntilResume ||
            previousZoom == null ||
            kotlin.math.abs(zoom - previousZoom) < 0.001
        ) {
            return
        }

        setRefreshSuspended(true)
    }

    private fun cacheScreenDistance(willMergedScreenDistance: Map<NRange<Int>, Double>) {
        for (i in MINIMUM_ZOOM..MAXIMUM_ZOOM) { // 0 ~ 21
            val firstMatchedDistance =
                willMergedScreenDistance.entries.firstOrNull { it.key.isInRange(i) }?.value
            mergedScreenDistanceCacheArray[i] = firstMatchedDistance ?: DEFAULT_SCREEN_DISTANCE
        }
    }

    private fun buildClusterer(): Clusterer<NClusterableMarkerInfo> {
        return ComplexBuilder<NClusterableMarkerInfo>()
            .applyEnableZoomLevel(clusterOptions.enableZoomRange)
            .maxScreenDistance(clusterOptions.mergeStrategy.maxMergeableScreenDistance)
            .animationDuration(clusterOptions.animationDuration.toInt())
            .updateOnChange(false)
            .thresholdStrategy(::thresholdStrategy)
            .tagMergeStrategy(::tagMergeStrategy)
            .clusterMarkerUpdater(::onClusterMarkerUpdate)
            .leafMarkerUpdater(::onClusterableMarkerUpdate)
            .markerManager(this)
            .minIndexingZoom(0)
            .maxIndexingZoom(0)
            .build()
    }

    private fun rebuildClusterer() {
        val oldClusterer = if (::clusterer.isInitialized) clusterer else null

        clusterer = buildClusterer().apply {
            addAll(clusterableMarkers)
            map = naverMap
        }

        suppressRelease = true
        oldClusterer?.map = null
        suppressRelease = false
    }

    fun setRefreshSuspended(suspended: Boolean) {
        if (suspended == isRefreshSuspended) return

        if (suspended) {
            flushPendingOverlayPrune()
            suspendedClusterOverlays =
                overlayController.takeOverlays(NOverlayType.CLUSTERABLE_MARKER)
            isRefreshSuspended = true
            return
        }

        val previousOverlays = suspendedClusterOverlays
        suspendedClusterOverlays = emptyMap()
        isRefreshSuspended = false

        rebuildClusterer()
        scheduleSuspendedOverlayPrune(previousOverlays)
        scheduleInvalidateView()
    }

    private fun scheduleSuspendedOverlayPrune(previousOverlays: Map<NOverlayInfo, Overlay>) {
        if (previousOverlays.isEmpty()) return

        pendingPruneOverlays = previousOverlays
        suspendedOverlayPruneRunnable?.let(nowHandler::removeCallbacks)
        suspendedOverlayPruneRunnable = Runnable {
            try {
                detachStandaloneOverlays(pendingPruneOverlays)
                pendingPruneOverlays = emptyMap()
                viewInvalidator.invoke()
            } finally {
                suspendedOverlayPruneRunnable = null
            }
        }
        nowHandler.postDelayed(
            suspendedOverlayPruneRunnable!!,
            maxOf(afterAnimationInvalidateDelay, 120L),
        )
    }

    private fun flushPendingOverlayPrune() {
        suspendedOverlayPruneRunnable?.let(nowHandler::removeCallbacks)
        suspendedOverlayPruneRunnable = null

        if (pendingPruneOverlays.isEmpty()) return

        detachStandaloneOverlays(pendingPruneOverlays)
        pendingPruneOverlays = emptyMap()
        viewInvalidator.invoke()
    }

    private fun detachStandaloneOverlays(overlays: Map<NOverlayInfo, Overlay>) {
        for ((_, overlay) in overlays) {
            overlay.map = null
        }
    }

    // maybe caused by TLHC frame copy failed
    private fun scheduleInvalidateView() {
        nowViewInvalidationRunnable?.let { nowHandler.removeCallbacks(it) }
        nowViewInvalidationRunnable = Runnable {
            try {
                viewInvalidator.invoke()
            } finally {
                nowViewInvalidationRunnable = null
            }
        }
        nowHandler.postDelayed(nowViewInvalidationRunnable!!, afterAnimationInvalidateDelay)
    }

    private fun updateAfterAnimationInvalidateDelay(animationDuration: Long) {
        afterAnimationInvalidateDelay = if (animationDuration > 50) animationDuration else 50L
    }

    fun addClusterableMarkerAll(markers: List<NClusterableMarker>) {
        val newMarkers: Map<NClusterableMarkerInfo, NClusterableMarker> =
            markers.associateBy { it.info }

        if (isRefreshSuspended) {
            clusterableMarkers.clear()
            clusterableMarkers.putAll(newMarkers)
            return
        }

        // If clusterer not yet initialized, do full build
        if (!::clusterer.isInitialized) {
            clusterableMarkers.clear()
            clusterableMarkers.putAll(newMarkers)
            rebuildClusterer()
            return
        }

        val existingKeys = clusterableMarkers.keys.toSet()
        val newKeys = newMarkers.keys.toSet()
        val toRemove = existingKeys - newKeys
        val toAdd = newMarkers.filterKeys { it !in existingKeys }
        val toRecluster = mutableMapOf<NClusterableMarkerInfo, NClusterableMarker>()
        val toUpdateVisibleOnly = mutableMapOf<NClusterableMarkerInfo, NClusterableMarker>()

        for (key in existingKeys.intersect(newKeys)) {
            val currentMarker = clusterableMarkers.getValue(key)
            val nextMarker = newMarkers.getValue(key)

            if (hasSameMarkerState(currentMarker, nextMarker)) continue

            if (hasStructuralChange(currentMarker, nextMarker)) {
                toRecluster[key] = nextMarker
            } else {
                toUpdateVisibleOnly[key] = nextMarker
            }
        }

        if (toRemove.isEmpty() &&
            toAdd.isEmpty() &&
            toRecluster.isEmpty() &&
            toUpdateVisibleOnly.isEmpty()
        ) {
            return
        }

        for (key in toRemove) {
            clusterableMarkers.remove(key)
            clusterer.remove(key)
        }

        for (key in toRecluster.keys) {
            clusterableMarkers.remove(key)
            clusterer.remove(key)
        }

        if (toAdd.isNotEmpty()) {
            clusterableMarkers.putAll(toAdd)
            clusterer.addAll(toAdd)
        }

        if (toRecluster.isNotEmpty()) {
            clusterableMarkers.putAll(toRecluster)
            clusterer.addAll(toRecluster)
        }

        if (toUpdateVisibleOnly.isNotEmpty()) {
            clusterableMarkers.putAll(toUpdateVisibleOnly)
            updateVisibleMarkers(toUpdateVisibleOnly)
        }
    }

    fun deleteClusterableMarker(overlayInfo: NOverlayInfo) {
        val clusterOverlayInfo = NClusterableMarkerInfo(overlayInfo.id, mapOf(), LatLng.INVALID)
        clusterableMarkers.remove(clusterOverlayInfo)

        if (isRefreshSuspended) {
            return
        }

        if (::clusterer.isInitialized) {
            clusterer.remove(clusterOverlayInfo)
        } else {
            overlayController.deleteOverlay(overlayInfo)
        }
    }

    fun clearClusterableMarker() {
        clusterableMarkers.clear()

        if (isRefreshSuspended) {
            return
        }

        overlayController.clearOverlays(NOverlayType.CLUSTERABLE_MARKER)
        rebuildClusterer()
    }

    private fun onClusterMarkerUpdate(
        clusterMarkerInfo: ClusterMarkerInfo, marker: Marker,
    ) {
        val info = clusterMarkerInfo.tag as? NClusterInfo? ?: return

        marker.isVisible = false
        if (isRefreshSuspended) return

        sendClusterMarkerEvent(info)
        scheduleInvalidateView()
    }

    private fun sendClusterMarkerEvent(info: NClusterInfo) {
        messageSender.invoke("clusterMarkerBuilder", info.toMessageable())
    }

    private fun hasSameMarkerState(
        currentMarker: NClusterableMarker,
        nextMarker: NClusterableMarker,
    ): Boolean {
        return !hasStructuralChange(currentMarker, nextMarker) &&
            currentMarker.wrappedMarker == nextMarker.wrappedMarker
    }

    private fun hasStructuralChange(
        currentMarker: NClusterableMarker,
        nextMarker: NClusterableMarker,
    ): Boolean {
        return currentMarker.info.point != nextMarker.info.point ||
            currentMarker.info.tags != nextMarker.info.tags
    }

    private fun updateVisibleMarkers(
        markers: Map<NClusterableMarkerInfo, NClusterableMarker>,
    ) {
        var didUpdateVisibleMarker = false

        for ((info, clusterableMarker) in markers) {
            val currentOverlay =
                overlayController.getOverlay(info.messageOverlayInfo) as? Marker ?: continue
            overlayController.saveOverlayWithAddable(clusterableMarker.wrappedMarker, currentOverlay)
            didUpdateVisibleMarker = true
        }

        if (didUpdateVisibleMarker) {
            scheduleInvalidateView()
        }
    }

    private fun onClusterableMarkerUpdate(
        clusterableMarkerInfo: LeafMarkerInfo, marker: Marker,
    ) {
        if (isRefreshSuspended) {
            marker.isVisible = false
            return
        }

        DefaultLeafMarkerUpdater().updateLeafMarker(clusterableMarkerInfo, marker)
        marker.icon = MarkerIcons.BLACK

        val nClusterableMarker = clusterableMarkerInfo.tag as NClusterableMarker
        val nMarker = nClusterableMarker.wrappedMarker
        overlayController.saveOverlayWithAddable(nMarker, marker)
        scheduleInvalidateView()
    }

//    private fun distanceStrategy(zoom: Int, node: Node, node1: Node): Double {
//        val defaultStrategy = DefaultDistanceStrategy()
//        val clusterableMarker1 = node.tag as NClusterNode?
//        val clusterableMarker2 = node1.tag as NClusterNode?
//
////        // clusterOptions.mergeStrategy.minClusterChildCount개 부터 합칠 수 있도록 한다
//        val minCount = clusterOptions.mergeStrategy.minClusterChildCount
//        Log.d("ClusteringController", "합칠 최소 개수: $minCount")
//
//        if (clusterableMarker1 is NClusterInfo || clusterableMarker2 is NClusterInfo) {
//            Log.d("ClusteringController", "클러스터 정보: $clusterableMarker1, $clusterableMarker2")
//            // early return : large first
//            if (
//                clusterableMarker1 is NClusterInfo && clusterableMarker1.children.size >= minCount
//                || clusterableMarker2 is NClusterInfo && clusterableMarker2.children.size >= minCount
//            ) {
//                return defaultStrategy.getDistance(zoom, node, node1)
//            }
//
//            val hashSet = hashSetOf<NClusterableMarkerInfo>()
//
//            if (clusterableMarker1 is NClusterInfo) hashSet.addAll(clusterableMarker1.children)
//            if (clusterableMarker2 is NClusterInfo) hashSet.addAll(clusterableMarker2.children)
//
//            val fullCount = hashSet.size
//
//            Log.d("ClusteringController", "노드 하위 개수: $fullCount")
//            if (fullCount < minCount) return Float.MAX_VALUE.toDouble()
//        }

//        if (clusterableMarker1 != null && clusterableMarker2 != null) {
//            val tagRangeMap = clusterOptions.mergeStrategy.mergeByEachTagEnableZoomRanges
//            for ((tagKey, range) in tagRangeMap) { //  태그 일치 여부 확인
//                if (!range.isInRange(zoom)) continue
//                val tag: String = when (clusterableMarker1) {
//                    is NClusterableMarker -> clusterableMarker1.info.tags[tagKey] ?: continue
//                    is NClusterInfo -> clusterableMarker1.mergedTag ?: continue
//                }
//                val tag2: String = when (clusterableMarker2) {
//                    is NClusterableMarker -> clusterableMarker2.info.tags[tagKey] ?: continue
//                    is NClusterInfo -> clusterableMarker2.mergedTag ?: continue
//                }
//
//                if (tag == tag2) return -1.0
//                continue
//            }
//        }
//
//        return defaultStrategy.getDistance(zoom, node, node1)
//    }
//

    // Access Time: O(1)
    // Running at Marker Add Time.
    private fun thresholdStrategy(zoom: Int): Double {
        return try {
            mergedScreenDistanceCacheArray[zoom]
        } catch (e: IndexOutOfBoundsException) {
            DEFAULT_SCREEN_DISTANCE
        }
    }

    private fun tagMergeStrategy(cluster: Cluster): Any {
        var mergedTagKey: String? = null
        val children = mutableListOf<NClusterableMarkerInfo>()

        for (node in cluster.children) {
            when (val data = node.tag) {
                is NClusterableMarker -> children.add(data.info)
                is NClusterInfo -> {
                    if (mergedTagKey == null) mergedTagKey = data.mergedTagKey
                    children.addAll(data.children)
                }
            }
        }

        // ** 태그 병합 기능은 보류합니다. **

        // 어떤 태그 키와 값으로 합쳐졌는지
        // 후보군
//        val kindTagKV = children.first().tags

//        val nowZoomLevel = naverMap.cameraPosition.zoom
        // 후보군을 순회하며 같은 태그 키와 값이 있는지 확인
        // (이것만으로는 부족. 태그가 같더라도, 다른 태그에 의해 합쳐지는 경우도 존재.
        // 해당 줌 레벨에서 확인 필요.
        //  or distanceStrategy에서 확인하는 방법이 필요할 듯

//        mergedTagKey = mergedTagKey ?: kindTagKV.entries.firstOrNull { (key, value) ->
//            children.all {
//                val includedTag = it.tags[key] == value
//                if (!includedTag) return@all false
//
//                val includedInZoomRange = clusterOptions
//                    .mergeStrategy
//                    .mergeByEachTagEnableZoomRanges[key]
//                    ?.isInRange(nowZoomLevel) == true
//
//                Log.d("ClusteringController", "태그 병합 확인: $key, $value, $includedInZoomRange")
//                return@all includedInZoomRange
//            }
//        }?.key

        return NClusterInfo(
            children = children,
            clusterSize = children.size,
            mergedTagKey = mergedTagKey,
            mergedTag = null, // kindTagKV[mergedTagKey],
            position = cluster.position,
        )
    }

    override fun retainMarker(info: MarkerInfo): Marker {
        val marker = Marker(info.position)
        if (isRefreshSuspended) {
            marker.isVisible = false
            return marker
        }

        when (val data = info.tag) {
//            is NClusterableMarker -> {
//                val nMarker = data.wrappedMarker
//                overlayController.saveOverlayWithAddable(nMarker, marker)
//            }
            is NClusterInfo -> overlayController.saveOverlay(
                marker,
                data.markerInfo.messageOverlayInfo
            )
        }
        return marker
    }

    override fun releaseMarker(info: MarkerInfo, marker: Marker) {
        if (suppressRelease || isRefreshSuspended) return
        when (val data = info.tag) {
            is NClusterableMarker -> overlayController.deleteOverlay(data.info)
            is NClusterInfo -> overlayController.deleteOverlay(data.markerInfo.messageOverlayInfo)
        }
    }

    fun dispose() {
        if (::clusterer.isInitialized) {
            clusterer.map = null
            clusterer.clear()
        }
        flushPendingOverlayPrune()
        // strict remove reference (callback remove, if needed)
//        val builder = ComplexBuilder<NClusterableMarkerInfo>()
//        clusterer = builder.build()
//        clusterer.map = naverMap
//        clusterer.map = null
//        clusterer.clear()

        clusterableMarkers.clear()
    }

    // --- extension functions ---
    private fun ComplexBuilder<NClusterableMarkerInfo>.applyEnableZoomLevel(range: NRange<Int>): ComplexBuilder<NClusterableMarkerInfo> {
        val min = range.min ?: MINIMUM_ZOOM
        val max = range.max ?: MAXIMUM_ZOOM
        return minClusteringZoom(min).maxClusteringZoom(max).minIndexingZoom(min)
            .maxIndexingZoom(max)
    }
}
