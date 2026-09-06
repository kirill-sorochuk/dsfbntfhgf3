import SwiftUI
import AVKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Видеоплеер для заставки
struct LoopingVideoPlayerView: UIViewRepresentable {
    let videoURL: URL?

    func makeUIView(context: Context) -> UIView {
        let view = VideoPlayerUIView()
        if let url = videoURL {
            view.configure(url: url)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) { }
}

class VideoPlayerUIView: UIView {
    private var playerLayer = AVPlayerLayer()
    private var player: AVPlayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        layer.addSublayer(playerLayer)
    }

    func configure(url: URL) {
        player = AVPlayer(url: url)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        player?.isMuted = true

        // Зацикливание
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidFinishPlaying),
            name: .AVPlayerItemDidPlayToEndTime,
            object: player?.currentItem
        )
        player?.play()
    }

    @objc private func playerDidFinishPlaying() {
        player?.seek(to: .zero)
        player?.play()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// SwiftUI wrapper for macOS (NSViewRepresentable)
#if os(macOS)
struct LoopingVideoPlayerNSView: NSViewRepresentable {
    let videoURL: URL?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        if let url = videoURL {
            let player = AVPlayer(url: url)
            let layer = AVPlayerLayer()
            layer.player = player
            layer.videoGravity = .resizeAspect
            view.layer = layer
            player.isMuted = true
            player.play()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { }
}
#endif

// MARK: - Кроссплатформенный видеоплеер
struct LoopingVideoView: View {
    let videoName: String

    var body: some View {
        if let url = Bundle.main.url(forResource: videoName, withExtension: "mp4") {
            #if os(iOS)
            LoopingVideoPlayerView(videoURL: url)
                .aspectRatio(contentMode: .fit)
            #else
            LoopingVideoPlayerNSView(videoURL: url)
                .aspectRatio(contentMode: .fit)
            #endif
        } else {
            // Fallback — изображение маскота
            Image("MascotAstronaut")
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }
}
