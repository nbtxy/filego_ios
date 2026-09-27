import AVFoundation
import AVKit
import UIKit

/**
 视频预览：全屏和画中画（应用外浮窗）。

 不走 QuickLook：它的播放器既没有画中画，离开 App 也会停。这里嵌一个
 `AVPlayerViewController`——全屏按钮和画中画都是它自带的——外面仍是我们自己的
 导航栏和菜单，和 `FilePreviewContainerViewController` 同一个结构，理由见那边的注释。

 画中画的难点不在开启，在**收尾**：浮窗开着时用户按返回离开这一页，控制器一释放
 浮窗就跟着没了。所以开浮窗时由 `PictureInPictureKeeper` 强持有本页，浮窗关掉才放；
 用户点浮窗上的「还原」而本页已经不在导航栈里时，把它推回原来的导航控制器。
 */
@MainActor
final class VideoPreviewController: UIViewController {
    private let file: PreviewTemporaryFile
    private let onCreateShareLink: (UIViewController) -> Void
    private let player: AVPlayer
    private let playerController = AVPlayerViewController()

    private var isInPictureInPicture = false
    /// 开浮窗那一刻所在的导航控制器。本页被 pop 之后「还原」要推回这里。
    private weak var homeNavigation: UINavigationController?

    /**
     横屏时的沉浸布局：没有导航栏，播放器铺满。

     横屏有两个来源——点旋转按钮，或者用户自己转手机——两者走同一条路，都由
     `viewWillTransition` 按尺寸判定，所以这里只是一个状态，不记录是谁触发的。
     */
    private var isLandscape = false

    /**
     旋转按钮。本想放进系统控制栏、挨着全屏按钮，但 AVKit 在 iOS 上不开放往控制栏
     加按钮（`transportBarCustomMenuItems` / `contextualActions` 只有 tvOS、visionOS）。
     退而求其次：浮在画面右侧中间，**跟系统控件同一个节奏显隐**——点画面出现，
     播放中几秒没动静就淡出，暂停时一直在——这样它不会一直挡着画面。
     */
    private let rotateButton = UIButton(type: .system)
    private var rotateButtonHideTask: Task<Void, Never>?
    private var timeControlObservation: NSKeyValueObservation?
    /// 和 AVKit 控件自动隐藏的时长大致对齐。
    private static let controlsLinger: Duration = .seconds(3)
    private var insetConstraints: [NSLayoutConstraint] = []
    private var fillConstraints: [NSLayoutConstraint] = []

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var prefersStatusBarHidden: Bool { isLandscape }
    override var prefersHomeIndicatorAutoHidden: Bool { isLandscape }

    init(
        file: PreviewTemporaryFile,
        title: String,
        onCreateShareLink: @escaping (UIViewController) -> Void
    ) {
        self.file = file
        self.onCreateShareLink = onCreateShareLink
        self.player = AVPlayer(url: file.url)
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        // 必须在播放器装好之前：AVKit 在装配时就检查音频会话，那一刻不是 `.playback`
        // 它就判定画中画不可用，之后再改类别也不会回头重算。
        activateAudioSession()
        embedPlayer()
        buildRotateButton()
        buildMenu()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 从别的页面回来时会话可能已被交还（`stopPlayback`），重新接管。
        activateAudioSession()
        // 画中画还原回来时它本来就在播，不要打断。
        if player.timeControlStatus == .paused, !isInPictureInPicture { player.play() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isMovingFromParent || isBeingDismissed else { return }
        // 横着离开：文件列表不该以横屏、没导航栏的样子出现。画中画时同样要还原。
        if isLandscape {
            navigationController?.setNavigationBarHidden(false, animated: animated)
            requestOrientation(.portrait)
        }
        // 只有真的离开（pop / dismiss）才停；全屏是 present 在本页之上，不算离开。
        guard !isInPictureInPicture else { return }
        stopPlayback()
    }

    override func viewWillTransition(
        to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        // 只在本页在屏幕上时接管布局：画中画期间本页可能已离开导航栈。
        guard view.window != nil else { return }
        let landscape = size.width > size.height
        coordinator.animate(alongsideTransition: { _ in self.applyLayout(landscape: landscape) })
    }

    // MARK: - 播放器

    private func embedPlayer() {
        playerController.player = player
        playerController.delegate = self
        playerController.allowsPictureInPicturePlayback = true
        // 正在播放时回到桌面，自动变成浮窗。
        playerController.canStartPictureInPictureAutomaticallyFromInline = true
        playerController.entersFullScreenWhenPlaybackBegins = false
        playerController.exitsFullScreenWhenPlaybackEnds = true

        addChild(playerController)
        playerController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playerController.view)
        let player = playerController.view!
        // 竖屏贴安全区（导航栏下面）；横屏铺满整个 view，刘海和底部横条让系统控件自己避。
        insetConstraints = [
            player.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            player.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ]
        fillConstraints = [
            player.topAnchor.constraint(equalTo: view.topAnchor),
            player.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ]
        NSLayoutConstraint.activate(insetConstraints + [
            player.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            player.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        playerController.didMove(toParent: self)
    }

    // MARK: - 旋转按钮

    /**
     放在画面右侧、竖直居中：系统控件的顶排（全屏、AirPlay、静音）和底排（进度条、
     时间、更多）都占着，中间一排的快进按钮离右边缘还有距离，这里横竖屏都空着。
     */
    private func buildRotateButton() {
        rotateButton.addAction(
            UIAction { [weak self] _ in self?.toggleOrientation() }, for: .primaryActionTriggered)
        rotateButton.alpha = 0
        rotateButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rotateButton)
        NSLayoutConstraint.activate([
            rotateButton.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            rotateButton.centerYAnchor.constraint(equalTo: playerController.view.centerYAnchor)
        ])
        updateRotateButtonAppearance()

        // 点画面切换显隐，和 AVKit 的控件一起。不吞触摸：AVKit 自己也要这一下。
        let tap = UITapGestureRecognizer(target: self, action: #selector(playerTapped))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        playerController.view.addGestureRecognizer(tap)

        // 暂停时 AVKit 的控件一直在，这里跟着；恢复播放后再按时淡出。
        timeControlObservation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            let paused = player.timeControlStatus == .paused
            Task { @MainActor [weak self] in
                guard let self, self.rotateButton.alpha > 0 || paused else { return }
                self.showRotateButton()
            }
        }
        showRotateButton()
    }

    private func updateRotateButtonAppearance() {
        var config = UIButton.Configuration.filled()
        config.image = UIImage(
            systemName: isLandscape ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.45)
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
        rotateButton.configuration = config
        rotateButton.accessibilityLabel = (isLandscape
            ? R.Strings.previewVideoPortrait : R.Strings.previewVideoLandscape).localizedString()
    }

    @objc private func playerTapped() {
        if rotateButton.alpha > 0 { hideRotateButton() } else { showRotateButton() }
    }

    /// 出现；在播就排一次淡出，暂停就一直留着。
    private func showRotateButton() {
        rotateButtonHideTask?.cancel()
        UIView.animate(withDuration: 0.2) { self.rotateButton.alpha = 1 }
        guard player.timeControlStatus != .paused else { return }
        rotateButtonHideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.controlsLinger)
            guard !Task.isCancelled else { return }
            self?.hideRotateButton()
        }
    }

    private func hideRotateButton() {
        rotateButtonHideTask?.cancel()
        UIView.animate(withDuration: 0.3) { self.rotateButton.alpha = 0 }
    }

    private func toggleOrientation() {
        requestOrientation(isLandscape ? .portrait : .landscapeRight)
        showRotateButton()
    }

    /**
     强制转方向。`requestGeometryUpdate` 开着竖排方向锁定也生效——这正是这个按钮
     存在的理由：播放器自带的全屏只跟着设备转，锁定时永远是竖的。
     */
    private func requestOrientation(_ mask: UIInterfaceOrientationMask) {
        setNeedsUpdateOfSupportedInterfaceOrientations()
        navigationController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }

    private func applyLayout(landscape: Bool) {
        guard landscape != isLandscape else { return }
        isLandscape = landscape
        navigationController?.setNavigationBarHidden(landscape, animated: false)
        NSLayoutConstraint.deactivate(landscape ? insetConstraints : fillConstraints)
        NSLayoutConstraint.activate(landscape ? fillConstraints : insetConstraints)
        updateRotateButtonAppearance()
        view.bringSubviewToFront(rotateButton)
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        view.layoutIfNeeded()
    }

    /**
     只在看视频时接管音频。

     放在 App 启动时设置会让任何别的 App 里在放的音乐一打开 Stolnk 就被掐断；而
     `.playback` 又是画中画和锁屏后继续出声的前提，所以打开视频页时才设。
     */
    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    private func stopPlayback() {
        player.pause()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - 菜单

    private func buildMenu() {
        let createLink = UIAction(
            title: R.Strings.previewCreateShareLink.localizedString(),
            image: UIImage(systemName: "link")
        ) { [weak self] _ in
            guard let self else { return }
            onCreateShareLink(self)
        }
        let shareFile = UIAction(
            title: R.Strings.previewShareOriginalFile.localizedString(),
            image: UIImage(systemName: "square.and.arrow.up")
        ) { [weak self] _ in self?.presentShareSheet() }

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            menu: UIMenu(children: [createLink, shareFile]))
    }

    private func presentShareSheet() {
        let controller = UIActivityViewController(
            activityItems: [file.url], applicationActivities: nil)
        controller.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(controller, animated: true)
    }
}

// MARK: - 点画面

extension VideoPreviewController: UIGestureRecognizerDelegate {
    /// 和 AVKit 自己的点击手势并存，否则两边只有一个能收到。
    nonisolated func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    /// 点在 AVKit 的按钮（播放、快进、进度条……）上不算「点画面」：那一下不会让
    /// 系统控件消失，旋转按钮也不该消失。
    nonisolated func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
    ) -> Bool {
        MainActor.assumeIsolated {
            var view = touch.view
            while let current = view, current !== playerController.view {
                if current is UIControl { return false }
                view = current.superview
            }
            return true
        }
    }
}

// MARK: - 画中画

extension VideoPreviewController: AVPlayerViewControllerDelegate {
    /// 我们是内嵌而不是模态，开浮窗时没有东西需要收起。
    nonisolated func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(
        _ playerViewController: AVPlayerViewController
    ) -> Bool {
        false
    }

    nonisolated func playerViewControllerWillStartPictureInPicture(
        _ playerViewController: AVPlayerViewController
    ) {
        MainActor.assumeIsolated {
            isInPictureInPicture = true
            homeNavigation = navigationController
            PictureInPictureKeeper.shared.hold(self)
        }
    }

    nonisolated func playerViewControllerDidStopPictureInPicture(
        _ playerViewController: AVPlayerViewController
    ) {
        MainActor.assumeIsolated {
            isInPictureInPicture = false
            // 浮窗被关掉（而不是还原）且本页早已离开：没人再看了，停掉并交还音频。
            if viewIfLoaded?.window == nil { stopPlayback() }
            PictureInPictureKeeper.shared.release(self)
        }
    }

    /// 用户点了浮窗上的「还原」。本页还在导航栈里就什么都不用做；已经被 pop 了就推回去。
    nonisolated func playerViewController(
        _ playerViewController: AVPlayerViewController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
            @escaping (Bool) -> Void
    ) {
        MainActor.assumeIsolated {
            if navigationController != nil {
                completionHandler(true)
                return
            }
            let target = homeNavigation
                ?? UIApplication.shared.topViewController()?.navigationController
            guard let target else {
                completionHandler(false)
                return
            }
            // 顶上若有模态（比如另一个视频正全屏），先收起，否则推进去的页面看不见。
            if target.presentedViewController != nil {
                target.dismiss(animated: false)
            }
            target.pushViewController(self, animated: false)
            completionHandler(true)
        }
    }
}

/**
 画中画期间强持有那个视频页，让用户可以离开它而浮窗不消失。

 同时只留一个：系统本来也只允许一个画中画，新的开始时旧的已经被系统停了。
 */
@MainActor
final class PictureInPictureKeeper {
    static let shared = PictureInPictureKeeper()
    private var held: UIViewController?

    func hold(_ controller: UIViewController) { held = controller }

    func release(_ controller: UIViewController) {
        if held === controller { held = nil }
    }
}
