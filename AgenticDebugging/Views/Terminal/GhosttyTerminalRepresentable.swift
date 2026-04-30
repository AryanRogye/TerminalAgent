//
//  GhosttyTerminalRepresentable.swift
//  AgenticDebugging
//
//  Created by Aryan Rogye on 4/29/26.
//

import SwiftUI

struct GhosttyTerminalRepresentable: NSViewRepresentable {
    
    var onReady: ((TerminalCommands) -> Void)?
    
    func makeNSView(context: Context) -> GhosttyTerminalView {
        let v = GhosttyTerminalView()
        onReady?(v)
        return v
    }

    func updateNSView(_ nsView: GhosttyTerminalView, context: Context) {}
}
