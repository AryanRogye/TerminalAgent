//
//  WindowTitlebarAreaView.swift
//  ComfyBrowser
//
//  Created by Aryan Rogye on 12/19/25.
//

import AppKit
import SwiftUI

/// View To Set WindowTitlebarItems + Move TrafficLights
extension View {
    public func windowTitlebarArea<Content: View>(
        shouldShowContent      : Binding<Bool>,
        shouldHideTrafficLights: Binding<Bool>,
        @ViewBuilder content   : @escaping () -> Content,
    ) -> some View {
        self
            .background(WindowTitlebarArea(
                shouldShowContent: shouldShowContent,
                shouldHideTrafficLights: shouldHideTrafficLights,
                content: content
            ))
    }
}

extension View {
    public func titlebarAppearsTransparent() -> some View {
        self
            .background(TitleBarTransparent())
    }
}

private struct TitleBarTransparent: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView()
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.titlebarAppearsTransparent = true
            nsView.window?.titleVisibility = .hidden
            nsView.window?.styleMask.insert(.fullSizeContentView)
        }
    }
}

/// When using SwiftUI, this will attach itself as the "background"
/// We set our view to be the "WindowTitlebarAreaView"
/// This value is taking in our
private struct WindowTitlebarArea<Content: View>: NSViewRepresentable {
    
    @Binding var shouldShowContent : Bool
    @Binding var shouldHideTrafficLights : Bool
    var content: Content
    
    init(
        shouldShowContent: Binding<Bool>,
        shouldHideTrafficLights: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self._shouldShowContent = shouldShowContent
        self._shouldHideTrafficLights = shouldHideTrafficLights
        self.content = content()
    }
    
    func makeNSView(context: Context) -> WindowTitlebarAreaView {
        let v = WindowTitlebarAreaView(
            rootView: AnyView(content)
        )
        return v
    }
    
    func updateNSView(_ nsView: WindowTitlebarAreaView, context: Context) {
        nsView.setContentHidden(!shouldShowContent)
        nsView.updateContent(AnyView(content))
        nsView.toggleTrafficLights(shouldHideTrafficLights)
    }
}

/// Main Window Class Behind SwiftUI View
private class WindowTitlebarAreaView: NSView {
    
    /// How far traffic lights should move right
    let moveRight : CGFloat = 5
    /// How far traffic lights should move down
    let moveDown  : CGFloat = 10
    
    private var didAttach = false
    private var leadingC: NSLayoutConstraint?
    private var centerYC: NSLayoutConstraint?
    private var heightC: NSLayoutConstraint?
    
    private let rootView: AnyView
    private lazy var hosting = NSHostingView(rootView: rootView)
    
    private var originalOrigins: [NSWindow.ButtonType: NSPoint] = [:]
    private var lastMode: String = ""

    private func currentMode(for window: NSWindow) -> String {
        // treat fullscreen vs not fullscreen as different baseline layouts
        window.styleMask.contains(.fullScreen) ? "fs" : "win"
    }
    
    private var frameObs: NSObjectProtocol?
    private var lastHidden: Bool?
    
    /// Setting up Titlebar
    init(rootView: AnyView) {
        self.rootView = rootView
        super.init(frame: .zero)
    }
    
    required init?(coder: NSCoder) {
        fatalError("Not Implemented")
    }

    /// When view loads, adjust traffic lights, and show titlebar buttons
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachIfNeededAndRefresh()
        observeWindow()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(NSWindow.didResizeNotification)
        NotificationCenter.default.removeObserver(NSWindow.didEnterFullScreenNotification)
        NotificationCenter.default.removeObserver(NSWindow.didExitFullScreenNotification)
    }
    
    /// Observe the Window
    private func observeWindow() {
        guard let window, frameObs == nil else { return }
        
        /// Did Resize
        frameObs = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.attachIfNeededAndRefresh()
        }
        
        /// Entered Fullscreen
        NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.attachIfNeededAndRefresh()
        }
        
        /// Exited Fullscreen
        NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.attachIfNeededAndRefresh()
        }
    }
    
    /// Attach SwiftUI Button, And Move Traffic Lights
    private func attachIfNeededAndRefresh(completion: @escaping () -> Void = { }) {
        guard let window else { return }
        guard let zoom = window.standardWindowButton(.zoomButton),
              let container = zoom.superview else { return }
        
        /// 🔴 🟡 🟢 |<- 8px ->| [your icon]
        let left_spacing : CGFloat = 8
        let height       : CGFloat = 24
        
        if didAttach {
            leadingC?.isActive = false
            centerYC?.isActive = false
            
            leadingC = hosting.leadingAnchor.constraint(equalTo: zoom.trailingAnchor, constant: left_spacing)
            centerYC = hosting.centerYAnchor.constraint(equalTo: zoom.centerYAnchor)
            
            NSLayoutConstraint.activate([leadingC!, centerYC!])
        } else {
            self.didAttach = true
            hosting.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(hosting)
            
            leadingC = hosting.leadingAnchor.constraint(equalTo: zoom.trailingAnchor, constant: left_spacing)
            centerYC = hosting.centerYAnchor.constraint(equalTo: zoom.centerYAnchor)
            heightC  = hosting.heightAnchor.constraint(equalToConstant: height)
            
            NSLayoutConstraint.activate([leadingC!, centerYC!, heightC!])
        }
        moveTrafficLights(in: window, completion: completion)
    }
    
    /// Update the hosting view
    public func updateContent(_ newView: AnyView) {
        hosting.rootView = newView
    }
    
    public func setContentHidden(_ hidden: Bool) {
        hosting.isHidden = hidden
    }
    
    public func toggleTrafficLights(_ val: Bool) {
        guard lastHidden != val else { return }
        lastHidden = val
        
        window?.standardWindowButton(.closeButton)?.alphaValue = val ? 0 : 1
        window?.standardWindowButton(.miniaturizeButton)?.alphaValue = val ? 0 : 1
        window?.standardWindowButton(.zoomButton)?.alphaValue = val ? 0 : 1
        
        if let window {
            moveTrafficLights(in: window)
        }
    }

    /// Adjust Traffic Light Positions, based on constant values and NSWindow
    private func moveTrafficLights(in window: NSWindow, animated: Bool = true, completion: (() -> Void)? = nil) {
        func move(_ type: NSWindow.ButtonType) {
            guard let btn = window.standardWindowButton(type) else { return }
            
            if originalOrigins[type] == nil {
                originalOrigins[type] = btn.frame.origin
            }
            guard let base = originalOrigins[type] else { return }
            
            let new = NSPoint(x: base.x + moveRight, y: base.y - moveDown)
            
            if animated {
                btn.animator().setFrameOrigin(new)
            } else {
                btn.setFrameOrigin(new)
            }
        }
        
        if animated {
            animate({
                move(.closeButton)
                move(.miniaturizeButton)
                move(.zoomButton)
            }, completion: completion)
        } else {
            move(.closeButton)
            move(.miniaturizeButton)
            move(.zoomButton)
            completion?()
        }
    }
    
    @MainActor
    func animate(
        duration: TimeInterval = 0.18,
        timing: CAMediaTimingFunctionName = .easeInEaseOut,
        _ changes: @escaping () -> Void,
        completion: (() -> Void)? = nil
    ) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: timing)
            changes()
        } completionHandler: {
            completion?()
        }
    }
}
