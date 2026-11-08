import Foundation
import Photos
import UIKit

/// 网页端媒体条目 (Android: pojo/file/MessageMediaContent.java + PhotoFolder.java)
final class LWebMedia {
    let name: String
    /// 已导出到沙盒时是真实路径；否则是 phasset/<localIdentifier> 伪路径
    private(set) var path: String
    let length: Int64
    let isVideo: Bool
    let videoTime: String
    /// 全局序号，对应 /imageload?index=
    let index: Int
    let asset: PHAsset

    init(name: String, path: String, length: Int64, isVideo: Bool, videoTime: String, index: Int, asset: PHAsset) {
        self.name = name
        self.path = path
        self.length = length
        self.isVideo = isVideo
        self.videoTime = videoTime
        self.index = index
        self.asset = asset
    }

    static let pseudoPrefix = "phasset/"
    var isPseudo: Bool { path.hasPrefix(Self.pseudoPrefix) }
    var localIdentifier: String {
        isPseudo ? String(path.dropFirst(Self.pseudoPrefix.count)) : asset.localIdentifier
    }
}

/// 相册 (Android: pojo/file/PhotoFolder.java)
final class LWebPhotoFolder {
    let name: String
    let images: [LWebMedia]
    init(name: String, images: [LWebMedia]) {
        self.name = name
        self.images = images
    }
}

/// 相册索引 (Android: pojo/network/MediaResult.java + AnyData.mediaResult)
/// 网页端 /media 与 /imageload/* 的数据源；未导出的相册资源用伪路径按需导出。
final class LMediaIndex {
    static let shared = LMediaIndex()

    private let gate = NSLock()
    private var folders: [LWebPhotoFolder] = []
    private var allMediaMap: [Int: LWebMedia] = [:]
    private var assetsById: [String: PHAsset] = [:]
    private var builtAt: Date?
    private let ttl: TimeInterval = 20

    private init() {}

    // MARK: - 构建

    /// 对应 AnyData.mediaResult 的懒加载，必须在非主线程调用
    func ensureBuilt(force: Bool = false) {
        gate.lock()
        let fresh = builtAt.map { Date().timeIntervalSince($0) < ttl } ?? false
        gate.unlock()
        if !force && fresh && !allMediaMap.isEmpty { return }
        rebuild()
    }

    private func rebuild() {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            // 网页请求在后台线程处理，用户可能从未打开相册页触发授权，这里按需申请，否则 /media 永远为空
            let sem = DispatchSemaphore(value: 0)
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in sem.signal() }
            _ = sem.wait(timeout: .now() + 30)
            status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        }
        guard status == .authorized || status == .limited else {
            gate.lock()
            folders = []
            allMediaMap = [:]
            assetsById = [:]
            builtAt = Date()
            gate.unlock()
            return
        }
        var collections: [(String, PHFetchResult<PHAssetCollection>)] = []
        collections.append(("自建相册", PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)))
        // 相机卷相当于 Android 里按目录分桶的 Camera 相册
        collections.append(("系统相册", PHAssetCollection.fetchAssetCollections(with: .smartAlbum,
                                                                                subtype: .smartAlbumUserLibrary,
                                                                                options: nil)))

        var built: [LWebPhotoFolder] = []
        var map: [Int: LWebMedia] = [:]
        var ids: [String: PHAsset] = [:]
        var globalIndex = 0
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        for (_, result) in collections {
            result.enumerateObjects { collection, _, _ in
                guard let title = collection.localizedTitle, !title.isEmpty else { return }
                let fetch = PHAsset.fetchAssets(in: collection, options: options)
                guard fetch.count > 0 else { return }
                var images: [LWebMedia] = []
                fetch.enumerateObjects { asset, _, _ in
                    let media = Self.makeMedia(asset: asset, index: globalIndex)
                    images.append(media)
                    map[globalIndex] = media
                    ids[asset.localIdentifier] = asset
                    globalIndex += 1
                }
                built.append(LWebPhotoFolder(name: title, images: images))
            }
        }

        gate.lock()
        folders = built
        allMediaMap = map
        assetsById = ids
        builtAt = Date()
        gate.unlock()
        LLog.debug("web media index built: \(built.count) folders, \(map.count) items")
    }

    private static func makeMedia(asset: PHAsset, index: Int) -> LWebMedia {
        let resource = PHAssetResource.assetResources(for: asset).first
        let name = resource?.originalFilename ?? "\(asset.localIdentifier.prefix(8)).\(asset.mediaType == .video ? "mov" : "jpg")"
        let isVideo = asset.mediaType == .video
        let videoTime = isVideo ? MediaKind.format(seconds: asset.duration) : ""
        if let cached = MediaExporter.shared.cached(for: asset), FileManager.default.fileExists(atPath: cached.path) {
            return LWebMedia(name: name, path: cached.path, length: cached.length, isVideo: isVideo,
                             videoTime: videoTime, index: index, asset: asset)
        }
        // 相册资源未导出前拿不到公开的文件大小，导出后（/imageload、/compressMedias、下载）会补上
        return LWebMedia(name: name, path: LWebMedia.pseudoPrefix + asset.localIdentifier,
                         length: 0, isVideo: isVideo, videoTime: videoTime, index: index, asset: asset)
    }

    // MARK: - 查询

    var photoFolders: [LWebPhotoFolder] {
        gate.lock()
        defer { gate.unlock() }
        return folders
    }

    func media(at index: Int) -> LWebMedia? {
        gate.lock()
        defer { gate.unlock() }
        return allMediaMap[index]
    }

    func asset(forLocalId id: String) -> PHAsset? {
        gate.lock()
        defer { gate.unlock() }
        return assetsById[id]
    }

    /// 伪路径 → 真实沙盒路径，必要时按需导出（阻塞等待，网页请求在后台线程处理）
    func resolve(path: String, timeout: TimeInterval = 180) -> String? {
        if !path.hasPrefix(LWebMedia.pseudoPrefix) {
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }
        let localId = String(path.dropFirst(LWebMedia.pseudoPrefix.count))
        guard let asset = asset(forLocalId: localId) else {
            guard let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil).firstObject else { return nil }
            return export(fetched, timeout: timeout)
        }
        return export(asset, timeout: timeout)
    }

    private func export(_ asset: PHAsset, timeout: TimeInterval) -> String? {
        let expected = MediaExporter.shared.expectedPath(for: asset)
        if FileManager.default.fileExists(atPath: expected), ResumeStore.fileSize(expected) > 0 {
            return expected
        }
        let sem = DispatchSemaphore(value: 0)
        var result: String?
        MediaExporter.shared.export([asset], each: { message, _ in
            result = message?.path
        }, completion: {
            sem.signal()
        })
        guard sem.wait(timeout: .now() + timeout) == .success else {
            LLog.debug("media export timeout")
            return nil
        }
        return result
    }

    /// 对应 /imageload/*：网页相册用缩略图，CSS 显示框 150px，按 2 倍取图避免高分屏发虚
    func thumbnailData(index: Int, timeout: TimeInterval = 20) -> Data? {
        guard let asset = media(at: index)?.asset else { return nil }
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        // SDK 里 average/packet 已移除，.none 会直接返回更大的缓存版本；
        // 清晰度靠「请求尺寸=显示像素×倍率」保证，缩放滤镜用 .fast 足够
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        var image: UIImage?
        let sem = DispatchSemaphore(value: 0)
        manager.requestImage(for: asset, targetSize: CGSize(width: 320, height: 320),
                             contentMode: .aspectFill, options: options) { result, _ in
            image = result
            sem.signal()
        }
        guard sem.wait(timeout: .now() + timeout) == .success, let image else { return nil }
        return image.pngData()
    }
}

private extension PHFetchResult where ObjectType == PHAsset {    var firstObject: PHAsset? {
        count > 0 ? object(at: 0) : nil
    }
}
