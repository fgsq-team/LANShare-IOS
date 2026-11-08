import SwiftUI
import AVFoundation
import ImageIO
import Photos
import CoreImage.CIFilterBuiltins

// MARK: - 图片解码

/// 缩略图与预览统一按「显示像素」降采样解码。
/// 直接 UIImage(contentsOfFile:) 拿整图再交给 SwiftUI 缩放会又慢又发虚，
/// ImageIO 的缩略图管线用盒式滤波降采样，同样尺寸下明显更清晰。
enum LImageLoader {
    static func image(path: String, maxPixel: CGFloat) -> UIImage? {
        // GIF 交给整图解码，保留动画（缩略图管线只会给第一帧）
        guard (path as NSString).pathExtension.lowercased() != "gif" else {
            return UIImage(contentsOfFile: path)
        }
        let url = URL(fileURLWithPath: path)
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else {
            return UIImage(contentsOfFile: path)
        }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64.0, maxPixel),
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else {
            return UIImage(contentsOfFile: path)
        }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    /// 在后台线程解码，避免大图卡住滚动
    static func load(path: String, maxPixel: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { image(path: path, maxPixel: maxPixel) }.value
    }
}

// MARK: - 图片预览 (Android: ReviewImages + preview_photo.xml)

/// 预览页的一张照片：沙盒文件或相册资源（相册资源直接取图，不必先导出到沙盒）
struct ImagePage: Identifiable, Equatable {
    let id: String
    let title: String
    var path: String?
    var asset: PHAsset?

    static func file(_ filePath: String) -> ImagePage {
        ImagePage(id: filePath, title: (filePath as NSString).lastPathComponent, path: filePath)
    }

    static func photo(_ asset: PHAsset) -> ImagePage {
        ImagePage(id: "phasset:" + asset.localIdentifier, title: "", asset: asset)
    }
}

struct ImageViewerSheet: View {
    let pages: [ImagePage]
    @State private var index: Int
    @Environment(\.dismiss) private var dismiss

    init(pages: [ImagePage], index: Int = 0) {
        self.pages = pages
        _index = State(initialValue: min(max(index, 0), max(pages.count - 1, 0)))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { offset, page in
                    ZoomableImage(page: page).tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            topBar
        }
    }

    /// 左右两侧等宽，中间的计数才能真正居中 (Android: preview_top_bar 48dp)
    private var topBar: some View {
        HStack(spacing: 0) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            Spacer(minLength: 0)
            VStack(spacing: 1) {
                Text("\(index + 1)/\(pages.count)").font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                if !currentTitle.isEmpty {
                    Text(currentTitle).font(.caption2).foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: 200)
            Spacer(minLength: 0)
            Button(action: sendCurrent) {
                Image(systemName: "paperplane.fill").font(.system(size: 16))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(.black.opacity(0.45))
    }

    private var currentTitle: String {
        pages.indices.contains(index) ? pages[index].title : ""
    }

    private func sendCurrent() {
        guard pages.indices.contains(index) else { return }
        let page = pages[index]
        if let path = page.path {
            let entry = FileEntry(name: (path as NSString).lastPathComponent, path: path, isDirectory: false,
                                  size: ResumeStore.fileSize(path), modified: Date())
            send([LFileStore.message(for: entry)])
            return
        }
        guard let asset = page.asset else { return }
        MediaExporter.shared.export([asset]) { message, _ in
            if let message { send([message]) }
        } completion: {}
    }

    private func send(_ files: [MessageFileContent]) {
        guard !files.isEmpty else { return }
        LAppModel.shared.pickDevice(title: "请选择需要接收的设备") { device in
            LANService.shared.sendFiles(files, to: device)
        }
    }
}

private struct ZoomableImage: View {
    let page: ImagePage
    @Environment(\.displayScale) private var displayScale
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else if failed {
                    Text("无法加载图片")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .scaleEffect(scale)
            .offset(offset)
            .gesture(MagnificationGesture()
                .onChanged { value in scale = min(max(lastScale * value, 1), 5) }
                .onEnded { _ in
                    lastScale = scale
                    if scale <= 1 { withAnimation { offset = .zero; lastOffset = .zero } }
                })
            .gesture(DragGesture()
                .onChanged { value in
                    guard scale > 1 else { return }
                    offset = CGSize(width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height)
                }
                .onEnded { _ in lastOffset = offset })
            .onTapGesture(count: 2) { toggleZoom() }
            .clipped()
            // 目标像素 = 显示区长边 × 倍率，取到的图正好铺满屏幕，既不糊也不浪费内存
            .task(id: page.id) {
                await loadImage(maxPixel: max(geo.size.width, geo.size.height) * displayScale)
            }
        }
    }

    private func toggleZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            if scale > 1 {
                scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero
            } else {
                scale = 2.5; lastScale = 2.5
            }
        }
    }

    private func loadImage(maxPixel: CGFloat) async {
        image = nil
        failed = false
        let loaded: UIImage?
        if let path = page.path {
            loaded = await LImageLoader.load(path: path, maxPixel: maxPixel)
        } else if let asset = page.asset {
            loaded = await MediaExporter.shared.previewImage(for: asset, maxPixel: maxPixel)
        } else {
            loaded = nil
        }
        guard !Task.isCancelled else { return }
        image = loaded
        failed = loaded == nil
    }
}

// MARK: - 二维码绘制 (Android: Zxing 生成)

struct QRCodeImageView: View {
    let content: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.tertiarySystemBackground))
                    .overlay(Text("无法生成二维码").font(.footnote).foregroundStyle(.secondary))
            }
        }
        .onAppear { image = QRCode.make(content) }
        .onChange(of: content) { _, _ in image = QRCode.make(content) }
    }
}

enum QRCode {
    static func make(_ content: String, scale: CGFloat = 8) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        let context = CIContext()
        guard let cg = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - 扫码 (Android: ZxingActivity)

struct QRScannerView: View {
    let onResult: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var denied = false

    var body: some View {
        ZStack {
            CameraPreview(onResult: { code in
                onResult(code)
                dismiss()
            }, onDeny: { denied = true })
            .ignoresSafeArea()

            VStack {
                HStack {
                    Button("取消") { dismiss() }
                        .padding(10)
                        .background(.black.opacity(0.4), in: Circle())
                    Spacer()
                    Text("扫码连接设备").foregroundStyle(.white)
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                Spacer()
                if denied {
                    Text("没有相机权限，请在系统设置中开启")
                        .font(.footnote)
                        .padding(10)
                        .background(.black.opacity(0.6), in: Capsule())
                }
            }
            .padding()
            .foregroundStyle(.white)
        }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let onResult: (String) -> Void
    let onDeny: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            context.coordinator.start(in: view)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { context.coordinator.start(in: view) } else { self.onDeny() }
                }
            }
        default:
            onDeny()
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onResult: (String) -> Void
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "fgsqw.qr.capture")
        private var started = false

        init(onResult: @escaping (String) -> Void) { self.onResult = onResult }

        func start(in view: UIView) {
            guard !started else { return }
            started = true
            queue.async {
                guard let device = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: device) else { return }
                self.session.beginConfiguration()
                if self.session.canAddInput(input) { self.session.addInput(input) }
                let output = AVCaptureMetadataOutput()
                if self.session.canAddOutput(output) {
                    self.session.addOutput(output)
                    output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                    output.metadataObjectTypes = [.qr, .ean13, .code128]
                }
                self.session.commitConfiguration()
                let preview = AVCaptureVideoPreviewLayer(session: self.session)
                preview.videoGravity = .resizeAspectFill
                preview.frame = view.bounds
                DispatchQueue.main.async {
                    view.layer.addSublayer(preview)
                    self.session.startRunning()
                }
            }
        }

        func stop() {
            guard started else { return }
            started = false
            session.stopRunning()
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                           from connection: AVCaptureConnection) {
            guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = object.stringValue else { return }
            stop()
            onResult(value)
        }
    }
}
