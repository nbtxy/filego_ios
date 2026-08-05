import UIKit

/// 登录后的抽屉外壳：主导航整屏右移，露出固定在左侧的「我的」。
///
/// 交互与 qingshu_ios 保持一致：根页左缘右滑打开，打开后左滑或点蒙层关闭；
/// 二级入口会先关闭抽屉，再推入主导航栈，因此系统返回手势仍只有一套。
@MainActor
final class DrawerContainerViewController: UIViewController, UIGestureRecognizerDelegate {
    private let mainNavigationController: MainNavigationController
    private let meViewController: MeViewController
    private let drawerNavigationController: UINavigationController

    private let mainContainer = UIView()
    private let scrim = UIView()
    private let drawerDim = UIView()

    private let widthFraction: CGFloat = 0.82
    private var isOpen = false
    private var dragProgress: CGFloat?
    private var screenCorner: CGFloat = 0
    private var edgePan: UIScreenEdgePanGestureRecognizer!
    private var closePan: UIPanGestureRecognizer!

    private var drawerWidth: CGFloat { max(1, view.bounds.width * widthFraction) }
    private var currentProgress: CGFloat { dragProgress ?? (isOpen ? 1 : 0) }

    init(environment: AppEnvironment) {
        let main = MainNavigationController(environment: environment)
        self.mainNavigationController = main

        var navigateFromDrawer: ((UIViewController) -> Void)?
        let me = MeViewController(
            environment: environment,
            onNavigate: { viewController in navigateFromDrawer?(viewController) }
        )
        self.meViewController = me
        self.drawerNavigationController = UINavigationController(rootViewController: me)
        super.init(nibName: nil, bundle: nil)

        navigateFromDrawer = { [weak self] viewController in
            self?.setOpen(false, animated: true)
            self?.mainNavigationController.pushViewController(viewController, animated: true)
        }
        main.onOpenDrawer = { [weak self] in self?.setOpen(true, animated: true) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        configureDrawer()
        configureMainContent()
        installGestures()
        apply(progress: 0)
    }

    private func configureDrawer() {
        // qingshu_ios 的抽屉内容直接从个人信息开始，不额外显示「我的」标题栏。
        drawerNavigationController.setNavigationBarHidden(true, animated: false)
        drawerNavigationController.view.backgroundColor = .systemGroupedBackground
        addChild(drawerNavigationController)
        view.addSubview(drawerNavigationController.view)
        drawerNavigationController.didMove(toParent: self)

        drawerDim.backgroundColor = .black
        drawerDim.isUserInteractionEnabled = false
        view.addSubview(drawerDim)
    }

    private func configureMainContent() {
        addChild(mainNavigationController)
        view.addSubview(mainContainer)
        mainContainer.addSubview(mainNavigationController.view)
        mainNavigationController.didMove(toParent: self)

        mainNavigationController.view.layer.maskedCorners = [
            .layerMinXMinYCorner, .layerMinXMaxYCorner
        ]
        mainNavigationController.view.layer.cornerCurve = .continuous
        mainNavigationController.view.layer.masksToBounds = true

        mainContainer.layer.shadowColor = UIColor.black.cgColor
        mainContainer.layer.shadowRadius = 12
        mainContainer.layer.shadowOffset = CGSize(width: -2, height: 0)
        mainContainer.layer.shadowOpacity = 0

        scrim.backgroundColor = .white
        scrim.alpha = 0
        scrim.isUserInteractionEnabled = false
        scrim.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        scrim.layer.cornerCurve = .continuous
        scrim.layer.masksToBounds = true
        scrim.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(scrimTapped))
        )
        mainContainer.addSubview(scrim)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let savedProgress = currentProgress
        let safeTop = view.safeAreaInsets.top
        screenCorner = safeTop >= 55 ? 55 : (safeTop >= 40 ? 47.33 : 0)

        drawerNavigationController.view.transform = .identity
        drawerNavigationController.view.frame = CGRect(
            x: 0,
            y: safeTop + 1,
            width: drawerWidth,
            height: view.bounds.height - safeTop - 1
        )
        drawerDim.frame = CGRect(x: 0, y: 0, width: drawerWidth, height: view.bounds.height)

        mainContainer.transform = .identity
        mainContainer.frame = view.bounds
        mainNavigationController.view.frame = mainContainer.bounds
        scrim.frame = mainContainer.bounds
        apply(progress: savedProgress)
    }

    func importExternalFile(at url: URL) -> Bool {
        setOpen(false, animated: false)
        return mainNavigationController.importExternalFile(at: url)
    }

    func setOpen(_ open: Bool, animated: Bool) {
        let changed = open != isOpen
        isOpen = open
        dragProgress = nil
        if open { meViewController.refresh() }
        if changed { HapticManager.impact(.light) }

        let target: CGFloat = open ? 1 : 0
        guard animated else {
            apply(progress: target)
            return
        }
        UIView.animate(
            withDuration: 0.20,
            delay: 0,
            options: [.curveLinear, .allowUserInteraction]
        ) {
            self.apply(progress: target)
        }
    }

    private func apply(progress: CGFloat) {
        mainContainer.transform = CGAffineTransform(
            translationX: drawerWidth * progress,
            y: 0
        )

        let scale = 0.92 + 0.08 * progress
        drawerNavigationController.view.transform = CGAffineTransform(scaleX: scale, y: scale)
        drawerDim.alpha = 0.35 * (1 - progress)

        scrim.alpha = 0.5 * progress
        scrim.isUserInteractionEnabled = progress > 0.001

        let radius: CGFloat = progress > 0.001 ? screenCorner : 0
        mainNavigationController.view.layer.cornerRadius = radius
        scrim.layer.cornerRadius = radius
        mainContainer.layer.shadowOpacity = Float(0.12 * progress)
        mainContainer.layer.shadowPath = radius > 0
            ? UIBezierPath(
                roundedRect: mainContainer.bounds,
                byRoundingCorners: [.topLeft, .bottomLeft],
                cornerRadii: CGSize(width: radius, height: radius)
            ).cgPath
            : UIBezierPath(rect: mainContainer.bounds).cgPath
    }

    private func installGestures() {
        let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdge(_:)))
        edge.edges = .left
        edge.delegate = self
        view.addGestureRecognizer(edge)
        edgePan = edge

        let close = UIPanGestureRecognizer(target: self, action: #selector(handleClose(_:)))
        close.delegate = self
        view.addGestureRecognizer(close)
        closePan = close
    }

    @objc private func scrimTapped() {
        setOpen(false, animated: true)
    }

    @objc private func handleEdge(_ gesture: UIScreenEdgePanGestureRecognizer) {
        let translation = gesture.translation(in: view).x
        switch gesture.state {
        case .changed:
            dragProgress = min(1, max(0, translation / drawerWidth))
            apply(progress: dragProgress ?? 0)
        case .ended, .cancelled, .failed:
            let velocity = gesture.velocity(in: view).x
            setOpen(
                max(0, translation) + velocity * 0.12 > drawerWidth * 0.3,
                animated: true
            )
        default:
            break
        }
    }

    @objc private func handleClose(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view).x
        switch gesture.state {
        case .changed:
            dragProgress = min(1, max(0, (drawerWidth + min(0, translation)) / drawerWidth))
            apply(progress: dragProgress ?? 1)
        case .ended, .cancelled, .failed:
            let velocity = gesture.velocity(in: view).x
            let shouldClose = translation + velocity * 0.12 < -drawerWidth * 0.3
            setOpen(!shouldClose, animated: true)
        default:
            break
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === edgePan {
            return !isOpen && mainNavigationController.viewControllers.count == 1
        }
        if gestureRecognizer === closePan {
            guard isOpen else { return false }
            let velocity = closePan.velocity(in: view)
            return velocity.x < 0 && abs(velocity.x) > abs(velocity.y)
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }
}
