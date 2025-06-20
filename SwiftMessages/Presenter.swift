//
//  MessagePresenter.swift
//  SwiftMessages
//
//  Created by Timothy Moose on 7/30/16.
//  Copyright © 2016 SwiftKick Mobile LLC. All rights reserved.
//

import UIKit

@MainActor
protocol PresenterDelegate: AnimationDelegate {
    func hide(presenter: Presenter)
}

@MainActor
class Presenter: NSObject {
    
    // MARK: - API

    init(config: SwiftMessages.Config, view: UIView, delegate: PresenterDelegate) {
        self.config = config
        self.view = view
        self.delegate = delegate
        self.animator = Presenter.animator(forPresentationStyle: config.presentationStyle, delegate: delegate)
        if let identifiable = view as? Identifiable {
            id = identifiable.id
        } else {
            var mutableView = view
            id = withUnsafePointer(to: &mutableView) { "\($0)" }
        }

        super.init()
    }
    
    var id: String
    var config: SwiftMessages.Config
    let maskingView = MaskingView()
    let animator: Animator
    var isHiding = false
    let view: UIView

    var delayShow: TimeInterval? {
        if case .indefinite(let delay, _) = config.duration { return delay }
        return nil
    }

    var showDate: CFTimeInterval?

    /// Returns the required delay for hiding based on time shown
    var delayHide: TimeInterval? {
        if interactivelyHidden { return 0 }
        if case .indefinite(_, let minimum) = config.duration, let showDate = showDate {
            let timeIntervalShown = CACurrentMediaTime() - showDate
            return max(0, minimum - timeIntervalShown)
        }
        return nil
    }

    var pauseDuration: TimeInterval? {
        let duration: TimeInterval?
        switch self.config.duration {
        case .automatic:
            duration = 2
        case .seconds(let seconds):
            duration = seconds
        case .forever, .indefinite:
            duration = nil
        }
        return duration
    }

    /// Detects the scenario where the view was shown, but the containing view heirarchy was removed before the view
    /// was hidden. This unusual scenario could result in the message queue being blocked because the presented
    /// view was not properly hidden by SwiftMessages. `isOrphaned` allows the queuing logic to unblock the queue.
    var isOrphaned: Bool {
        return installed && view.window == nil
    }

    // MARK: - Constants

    @MainActor
    enum PresentationContext {
        case viewController(_: Weak<UIViewController>)
        case view(_: Weak<UIView>)
        
        func viewControllerValue() -> UIViewController? {
            switch self {
            case .viewController(let weak):
                return weak.value
            case .view:
                return nil
            }
        }
        
        func viewValue() -> UIView? {
            switch self {
            case .viewController(let weak):
                return weak.value?.view
            case .view(let weak):
                return weak.value
            }
        }
    }

    // MARK: - Variables

    private weak var delegate: PresenterDelegate?
    private var presentationContext = PresentationContext.viewController(Weak<UIViewController>(value: nil))
    private var installed = false
    private var interactivelyHidden = false;

    // MARK: - Showing and hiding

    private static func animator(forPresentationStyle style: SwiftMessages.PresentationStyle, delegate: AnimationDelegate) -> Animator {
        switch style {
        case .top:
            return TopBottomAnimation(style: .top, delegate: delegate)
        case .bottom:
            return TopBottomAnimation(style: .bottom, delegate: delegate)
        case .center:
            return PhysicsAnimation(delegate: delegate)
        case .custom(let animator):
            animator.delegate = delegate
            return animator
        }
    }

    func show(completion: @escaping AnimationCompletion) throws {
        try presentationContext = getPresentationContext()
        install()
        self.config.eventListeners.forEach { $0(.willShow(self.view)) }
        switch (self.view as? HapticMessage)?.defaultHaptic ?? config.haptic {
        case .error?: UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .warning?: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .success?: UINotificationFeedbackGenerator().notificationOccurred(.success)
        default: break
        }
        showAnimation() { completed in
            completion(completed)
            if completed {
                if self.config.dimMode.modal {
                    self.showAccessibilityFocus()
                } else {
                    self.showAccessibilityAnnouncement()
                }
                self.config.eventListeners.forEach { $0(.didShow(self.view)) }
            }
        }
    }

    private func showAnimation(completion: @escaping AnimationCompletion) {

        func dim(_ color: UIColor) {
            self.maskingView.backgroundColor = UIColor.clear
            UIView.animate(withDuration: 0.2, animations: {
                self.maskingView.backgroundColor = color
            })
        }

        func blur(style: UIBlurEffect.Style, alpha: CGFloat) {
            let blurView = UIVisualEffectView(effect: nil)
            blurView.alpha = alpha
            maskingView.backgroundView = blurView
            UIView.animate(withDuration: 0.3) {
                blurView.effect = UIBlurEffect(style: style)
            }
        }

        let context = animationContext()
        animator.show(context: context) { (completed) in
            completion(completed)
        }
        switch config.dimMode {
        case .none:
            break
        case .gray:
            dim(UIColor(white: 0, alpha: 0.3))
        case .color(let color, _):
            dim(color)
        case .blur(let style, let alpha, _):
            blur(style: style, alpha: alpha)
        }
    }

    private func showAccessibilityAnnouncement() {
        guard let accessibleMessage = view as? AccessibleMessage,
            let message = accessibleMessage.accessibilityMessage else { return }
        UIAccessibility.post(notification: UIAccessibility.Notification.announcement, argument: message)
    }

    private func showAccessibilityFocus() {
        guard let accessibleMessage = view as? AccessibleMessage,
            let focus = accessibleMessage.accessibilityElement ?? accessibleMessage.additionalAccessibilityElements?.first else { return }
        UIAccessibility.post(notification: UIAccessibility.Notification.layoutChanged, argument: focus)
    }

    func hide(animated: Bool, completion: @escaping AnimationCompletion) {
        isHiding = true
        self.config.eventListeners.forEach { $0(.willHide(self.view)) }
        let context = animationContext()
        let action = {
            if let viewController = self.presentationContext.viewControllerValue() as? WindowViewController {
                viewController.uninstall()
            }
            self.maskingView.removeFromSuperview()
            completion(true)
            self.config.eventListeners.forEach { $0(.didHide(self.view)) }
        }
        guard animated else {
            action()
            return
        }
        animator.hide(context: context) { (completed) in
            action()
        }

        func undim() {
            UIView.animate(withDuration: 0.2, delay: 0, options: .beginFromCurrentState, animations: {
                self.maskingView.backgroundColor = UIColor.clear
            }, completion: nil)
        }

        func unblur() {
            guard let view = maskingView.backgroundView as? UIVisualEffectView else { return }
            UIView.animate(withDuration: 0.2, delay: 0, options: .beginFromCurrentState, animations: { 
                view.effect = nil
            }, completion: nil)
        }
        
        switch config.dimMode {
        case .none:
            break
        case .gray:
            undim()
        case .color:
            undim()
        case .blur:
            unblur()
        }
    }

    private func animationContext() -> AnimationContext {
        return AnimationContext(messageView: view, containerView: maskingView, safeZoneConflicts: safeZoneConflicts(), interactiveHide: config.interactiveHide)
    }

    private func safeZoneConflicts() -> SafeZoneConflicts {
        guard let _ = maskingView.window else { return [] }
        let windowLevel: UIWindow.Level = {
            if let vc = presentationContext.viewControllerValue() as? WindowViewController {
                return vc.config.windowLevel ?? .normal
            }
            return .normal
        }()
        // TODO `underNavigationBar` and `underTabBar` should look up the presentation context's hierarchy
        // TODO for cases where both should be true (probably not an issue for typical height messages, though).
        let underNavigationBar: Bool = {
            if let vc = presentationContext.viewControllerValue() as? UINavigationController { return vc.sm_isVisible(view: vc.navigationBar) }
            return false
        }()
        let underTabBar: Bool = {
            if let vc = presentationContext.viewControllerValue() as? UITabBarController { return vc.sm_isVisible(view: vc.tabBar) }
            return false
        }()
        if windowLevel > .normal {
            // TODO seeing `maskingView.safeAreaInsets.top` value of 20 on
            // iPhone 8 with status bar window level. This seems like an iOS bug since
            // the message view's window is above the status bar. Applying a special rule
            // to allow the animator to revove this amount from the layout margins if needed.
            // This may need to be reworked if any future device has a legitimate 20pt top safe area,
            // such as with a potentially smaller notch.
            if maskingView.safeAreaInsets.top == 20 {
                return [.overStatusBar]
            } else {
                var conflicts: SafeZoneConflicts = []
                if maskingView.safeAreaInsets.top > 0 {
                    conflicts.formUnion(.sensorNotch)
                }
                if maskingView.safeAreaInsets.bottom > 0 {
                    conflicts.formUnion(.homeIndicator)
                }
                return conflicts
            }
        }
        var conflicts: SafeZoneConflicts = []
        if !underNavigationBar {
            conflicts.formUnion(.sensorNotch)
        }
        if !underTabBar {
            conflicts.formUnion(.homeIndicator)
        }
        return conflicts
    }

    private func getPresentationContext() throws -> PresentationContext {

        func newWindowViewController() -> UIViewController {
            let viewController = WindowViewController.newInstance(config: config)
            return viewController
        }

        switch config.presentationContext {
        case .automatic:
            #if SWIFTMESSAGES_APP_EXTENSIONS
            throw SwiftMessagesError.noRootViewController
            #else
            if let rootViewController = UIWindow.keyWindow?.rootViewController {
                let viewController = rootViewController.sm_selectPresentationContextTopDown(config)
                return .viewController(Weak(value: viewController))
            } else {
                throw SwiftMessagesError.noRootViewController
            }
            #endif
        case .window:
            let viewController = newWindowViewController()
            return .viewController(Weak(value: viewController))
        case .windowScene:
            let viewController = newWindowViewController()
            return .viewController(Weak(value: viewController))
        case .viewController(let viewController):
            let viewController = viewController.sm_selectPresentationContextBottomUp(config)
            return .viewController(Weak(value: viewController))
        case .view(let view):
            return .view(Weak(value: view))
        }
    }

    /*
     MARK: - Installation
     */

    func install() {

        func topLayoutConstraint(view: UIView, containerView: UIView, viewController: UIViewController?) -> NSLayoutConstraint {
            if case .top = config.presentationStyle.topBottomStyle, let nav = viewController as? UINavigationController, nav.sm_isVisible(view: nav.navigationBar) {
                return NSLayoutConstraint(item: view, attribute: .top, relatedBy: .equal, toItem: nav.navigationBar, attribute: .bottom, multiplier: 1.00, constant: 0.0)
            }
            return NSLayoutConstraint(item: view, attribute: .top, relatedBy: .equal, toItem: containerView, attribute: .top, multiplier: 1.00, constant: 0.0)
        }

        func bottomLayoutConstraint(view: UIView, containerView: UIView, viewController: UIViewController?) -> NSLayoutConstraint {
            if case .bottom = config.presentationStyle.topBottomStyle, let tab = viewController as? UITabBarController, tab.sm_isVisible(view: tab.tabBar) {
                return NSLayoutConstraint(item: view, attribute: .bottom, relatedBy: .equal, toItem: tab.tabBar, attribute: .top, multiplier: 1.00, constant: 0.0)
            }
            return NSLayoutConstraint(item: view, attribute: .bottom, relatedBy: .equal, toItem: containerView, attribute: .bottom, multiplier: 1.00, constant: 0.0)
        }

        func installMaskingView(containerView: UIView) {
            maskingView.translatesAutoresizingMaskIntoConstraints = false
            if let nav = presentationContext.viewControllerValue() as? UINavigationController {
                containerView.insertSubview(maskingView, belowSubview: nav.navigationBar)
            } else if let tab = presentationContext.viewControllerValue() as? UITabBarController {
                containerView.insertSubview(maskingView, belowSubview: tab.tabBar)
            } else {
                containerView.addSubview(maskingView)
            }
            maskingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor).isActive = true
            maskingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor).isActive = true
            topLayoutConstraint(view: maskingView, containerView: containerView, viewController: presentationContext.viewControllerValue()).isActive = true
            bottomLayoutConstraint(view: maskingView, containerView: containerView, viewController: presentationContext.viewControllerValue()).isActive = true
            if let keyboardTrackingView = config.keyboardTrackingView {
                maskingView.install(keyboardTrackingView: keyboardTrackingView)
            }
            // Update the container view's layout in order to know the masking view's frame
            containerView.layoutIfNeeded()
        }

        func installInteractive() {
            guard config.dimMode.modal else { return }
            if config.dimMode.interactive {
                maskingView.tappedHandler = { [weak self] in
                    guard let strongSelf = self else { return }
                    strongSelf.interactivelyHidden = true
                    strongSelf.delegate?.hide(presenter: strongSelf)
                }
            } else {
                // There's no action to take, but the presence of
                // a tap handler prevents interaction with underlying views.
                maskingView.tappedHandler = { }
            }
        }

        func installAccessibility() {
            var elements: [NSObject] = []
            if let accessibleMessage = view as? AccessibleMessage {
                if let message = accessibleMessage.accessibilityMessage {
                    let element = accessibleMessage.accessibilityElement ?? view
                    element.isAccessibilityElement = true
                    if element.accessibilityLabel == nil {
                        element.accessibilityLabel = message
                    }
                    elements.append(element)
                }
                if let additional = accessibleMessage.additionalAccessibilityElements {
                    elements += additional
                }
            } else {
                    elements += [view]
            }
            if config.dimMode.interactive {
                let dismissView = maskingViewOverlay()
                dismissView.accessibilityLabel = config.dimModeAccessibilityLabel
                dismissView.accessibilityTraits = UIAccessibilityTraits.button
                elements.append(dismissView)
            } else if config.dimMode.modal {
                let plainView = maskingViewOverlay()
                plainView.accessibilityTraits = UIAccessibilityTraits.none
                elements.append(plainView)
            }
            if config.dimMode.modal {
                maskingView.accessibilityViewIsModal = true
            }
            maskingView.accessibleElements = elements
        }
        
        func maskingViewOverlay() -> UIView {
            let overlayView = UIView(frame: maskingView.bounds)
            overlayView.translatesAutoresizingMaskIntoConstraints = true
            overlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            maskingView.addSubview(overlayView)
            maskingView.sendSubviewToBack(overlayView)
            overlayView.isUserInteractionEnabled = false
            overlayView.isAccessibilityElement = true
            
            return overlayView
        }

        installed = true
        guard let containerView = presentationContext.viewValue() else { return }
        (presentationContext.viewControllerValue() as? WindowViewController)?.install()
        installMaskingView(containerView: containerView)
        installInteractive()
        installAccessibility()
    }
}


