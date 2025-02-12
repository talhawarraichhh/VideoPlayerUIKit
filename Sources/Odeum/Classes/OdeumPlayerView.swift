//
//  OdeumPlayerView.swift
//  Odeum
//
//  Created by Nayanda Haberty on 23/01/21.
//

import Foundation
#if canImport(UIKit)
import UIKit
import AVFoundation
import AVKit

public class OdeumPlayerView: UIView {
    
    // MARK: - Subviews
    
    /// The container for progress bar + audio/fullscreen
    public lazy var bottomBarView: UIView = {
        let view = UIView()
        view.backgroundColor = .clear
        return view
    }()
    
    public lazy var bottomRightStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [audioButton, fullscreenButton])
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.distribution = .equalSpacing
        stack.spacing = 12
        return stack
    }()
    
    public lazy var audioButton: UIButton = {
        let button = UIButton(type: .custom)
        // For example: a speaker wave icon
        if #available(iOS 13.0, *) {
            button.setImage(UIImage(systemName: "speaker.wave.2.fill"), for: .normal)
        } else {
            // fallback for older iOS, e.g. use a stored asset
            button.setImage(UIImage(named: "audio_unmute"), for: .normal)
        }
        button.tintColor = .white
        button.addTarget(self, action: #selector(didTapAudio), for: .touchUpInside)
        return button
    }()
    
    public lazy var fullscreenButton: UIButton = {
        let button = UIButton(type: .custom)
        if #available(iOS 13.0, *) {
            button.setImage(UIImage(systemName: "rectangle.expand.vertical"), for: .normal)
        } else {
            button.setImage(UIImage(named: "fullscreen_icon"), for: .normal)
        }
        button.tintColor = .white
        button.addTarget(self, action: #selector(didTapFullscreen), for: .touchUpInside)
        return button
    }()

    
    public internal(set) lazy var progressBar: UISlider = {
        let bar = UISlider()
        bar.thumbTintColor = .white
        bar.minimumTrackTintColor = .red
        bar.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.5)
        bar.maximumValue = 1
        bar.minimumValue = 0
        bar.setThumbImage(makeCircle(), for: .normal)
        bar.setThumbImage(makeCircle(withSize: .init(width: 16, height: 16)), for: .highlighted)
        bar.addTarget(self, action: #selector(slided(_:)), for: .valueChanged)
        bar.addTarget(self, action: #selector(didSlide(_:)), for: .touchUpInside)
        bar.addTarget(self, action: #selector(didSlide(_:)), for: .touchUpOutside)
        return bar
    }()
    
    public internal(set) lazy var placeholderView: UIImageView = {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill
        view.backgroundColor = .clear
        view.clipsToBounds = true
        return view
    }()
    
    public internal(set) lazy var videoViewHolder: UIView = {
        let view = UIView()
        view.backgroundColor = .clear
        view.addGestureRecognizer(tapGestureRecognizer)
        return view
    }()
    
    public internal(set) lazy var playerControl: PlayControlView = {
        let control = PlayControlView()
        control.delegate = self
        return control
    }()
    
    public internal(set) lazy var spinner: UIActivityIndicatorView = .init(style: .white)
    
    lazy var tapGestureRecognizer: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(didTap(_:)))
        gesture.cancelsTouchesInView = false
        return gesture
    }()
    
    // MARK: - Player / State
    
    public var videoIsFinished: Bool {
        guard let duration = player.currentItem?.duration else { return false }
        return player.currentTime() >= duration
    }
    public var isBuffering: Bool {
        spinner.alpha < 1
    }
    
    // The center controls track these states:
    public var audioState: AudioState { playerControl.audioState }
    public var replayStep: ReplayStep {
        get { playerControl.replayStep }
        set { playerControl.replayStep = newValue }
    }
    public var playState: PlayState { playerControl.playState }
    public var forwardStep: ForwardStep {
        get { playerControl.forwardStep }
        set { playerControl.forwardStep = newValue }
    }
    public var fullScreenState: FullScreenState { playerControl.fullScreenState }
    
    public var videoItem: AVPlayerItem? {
        player.currentItem
    }
    public internal(set) var controlAppearance: ControlAppearanceState = .hidden
    public weak var delegate: OdeumPlayerViewDelegate?
    
    /// The main AVPlayer
    lazy var player: AVPlayer = {
        let player = AVPlayer()
        player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 1000),
            queue: .main
        ) { [weak self] time in
            self?.timeTracked(time)
        }
        player.actionAtItemEnd = .pause
        player.addObserver(self, forKeyPath: "timeControlStatus", options: [.old, .new], context: nil)
        return player
    }()
    
    /// The layer that displays the video
    lazy var playerLayer: AVPlayerLayer = {
        let layer = AVPlayerLayer(player: player)
        // Use fill if you want to crop; .resizeAspect if you prefer letterboxing
        layer.videoGravity = .resizeAspectFill
        return layer
    }()
    
    @IBInspectable
    public var videoControlShownDuration: NSNumber = 3
    
    @IBInspectable
    public var placeholderImage: UIImage? = nil {
        didSet {
            placeholderView.image = placeholderImage
        }
    }
    
    public internal(set) var url: URL?
    var previousTimeStatus: AVPlayer.TimeControlStatus?
    var hideWorker: DispatchWorkItem?
    weak var fullScreenViewController: UIViewController?
    var manuallySeek: Bool = false
    
    var videoControlShownTimeInterval: TimeInterval {
        .init(truncating: videoControlShownDuration)
    }
    
    // MARK: - Lifecycle
    
    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        buildView()
    }
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    deinit {
        player.removeObserver(self, forKeyPath: "timeControlStatus", context: nil)
    }
    
    public override func layoutSubviews() {
        super.layoutSubviews()
        // Size the video layer
        playerLayer.frame = videoViewHolder.bounds
        videoViewHolder.layer.addSublayer(playerLayer)
        
        // Round corners of center play controls
        playerControl.layer.cornerRadius = playerControl.bounds.height / 2
        playerControl.clipsToBounds = true
    }
    
    // MARK: - Setup
    
    func buildView() {
        makeControlTransparent()
        insertSubviewsInPlace()
        
        activatePlaceholderViewConstraints()
        activateVideoViewHolderConstraints()
        activatePlayerControlConstraints()
        
        // Add bottom bar (progress + audio + fullscreen)
        addSubview(bottomBarView)
        bottomBarView.addSubview(progressBar)
        bottomBarView.addSubview(bottomRightStack)
        activateBottomBarConstraints()
        
        activateSpinnerConstraints()
    }
    
    func makeControlTransparent() {
        playerControl.alpha = 0
        spinner.alpha = 0
        bottomBarView.alpha = 0
    }
    
    func insertSubviewsInPlace() {
        addSubview(placeholderView)
        addSubview(videoViewHolder)
        addSubview(spinner)
        
        // The center controls
        addSubview(playerControl)
    }
    
    // MARK: - Subview Constraints
    
    func activatePlaceholderViewConstraints() {
        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            placeholderView.topAnchor.constraint(equalTo: topAnchor),
            placeholderView.leftAnchor.constraint(equalTo: leftAnchor),
            placeholderView.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholderView.rightAnchor.constraint(equalTo: rightAnchor)
        ])
    }
    
    func activateVideoViewHolderConstraints() {
        videoViewHolder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            videoViewHolder.topAnchor.constraint(equalTo: topAnchor),
            videoViewHolder.leftAnchor.constraint(equalTo: leftAnchor),
            videoViewHolder.bottomAnchor.constraint(equalTo: bottomAnchor),
            videoViewHolder.rightAnchor.constraint(equalTo: rightAnchor)
        ])
    }
    
    func activatePlayerControlConstraints() {
            playerControl.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                playerControl.centerYAnchor.constraint(equalTo: centerYAnchor),
                playerControl.centerXAnchor.constraint(equalTo: centerXAnchor),
                playerControl.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 16),
                playerControl.leftAnchor.constraint(greaterThanOrEqualTo: leftAnchor, constant: 16),
                playerControl.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
                playerControl.rightAnchor.constraint(lessThanOrEqualTo: rightAnchor, constant: -16),
                playerControl.heightAnchor.constraint(lessThanOrEqualToConstant: 48),
                playerControl.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
                playerControl.widthAnchor.constraint(equalTo: playerControl.heightAnchor, multiplier: 3)
            ])
        }
    
    func activateBottomBarConstraints() {
        bottomBarView.translatesAutoresizingMaskIntoConstraints = false
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        bottomRightStack.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            // bottomBar pinned to the bottom, full width
            bottomBarView.leftAnchor.constraint(equalTo: leftAnchor),
            bottomBarView.rightAnchor.constraint(equalTo: rightAnchor),
            bottomBarView.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBarView.heightAnchor.constraint(equalToConstant: 50),
            
            // progressBar pinned to left side
            progressBar.leftAnchor.constraint(equalTo: bottomBarView.leftAnchor, constant: 12),
            progressBar.centerYAnchor.constraint(equalTo: bottomBarView.centerYAnchor),
            
            // bottomRightStack pinned to right
            bottomRightStack.rightAnchor.constraint(equalTo: bottomBarView.rightAnchor, constant: -12),
            bottomRightStack.centerYAnchor.constraint(equalTo: bottomBarView.centerYAnchor),
            
            // progressBar extends until bottomRightStack
            progressBar.rightAnchor.constraint(equalTo: bottomRightStack.leftAnchor, constant: -12),
        ])
    }
    
    func activateSpinnerConstraints() {
        spinner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            
            spinner.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 16),
            spinner.leftAnchor.constraint(greaterThanOrEqualTo: leftAnchor, constant: 16),
            spinner.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
            spinner.rightAnchor.constraint(lessThanOrEqualTo: rightAnchor, constant: -16)
        ])
    }
    
    // MARK: - Show/Hide
    
    func showSpinner() {
            self.spinner.startAnimating()
            UIView.animate(
                withDuration: 0.2,
                delay: 0,
                options: .curveEaseInOut,
                animations: {
                    self.spinner.alpha = 1
                },
                completion: nil
            )
        }
        
        func hideSpinner() {
            UIView.animate(
                withDuration: 0.2,
                delay: 0,
                options: .curveEaseInOut,
                animations: {
                    self.spinner.alpha = 0
                    self.placeholderView.alpha = 0
                },
                completion: { _ in
                    self.spinner.stopAnimating()
                }
            )
        }
    
    func showControl() {
           controlAppearance = .goingToShow
           UIView.animate(
               withDuration: 0.45,
               delay: .zero,
               options: .curveEaseInOut) { [weak progressBar, weak playerControl] in
                   progressBar?.alpha = 1
                   playerControl?.alpha = 1
               } completion: { [weak self] complete in
                   guard complete else { return }
                   self?.controlAppearance = .shown
               }
       }
    
    public func hideControl() {
        controlAppearance = .goingToHide
        UIView.animate(withDuration: 0.45, delay: .zero, options: .curveEaseInOut) {
            self.playerControl.alpha = 0
            self.bottomBarView.alpha = 0
        } completion: { _ in
            self.controlAppearance = .hidden
        }
    }
    
    @objc func didTapAudio() {
            // Toggle audio
            // For example:
            let isCurrentlyMute = audioState == .mute
            set(mute: !isCurrentlyMute)
        }
        
        @objc func didTapFullscreen() {
            // Switch fullscreen
            // For example:
            if fullScreenState == .minimize {
                goFullScreen()
            } else {
                dismissFullScreen()
            }
        }
}
public extension OdeumPlayerView {
    
    enum ControlAppearanceState: Equatable {
        case shown
        case goingToShow
        case goingToHide
        case hidden
    }
}
#endif
