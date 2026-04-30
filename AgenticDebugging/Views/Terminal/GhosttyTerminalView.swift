//
//  GhosttyTerminalView.swift
//  AgenticDebugging
//
//  Created by Aryan Rogye on 4/29/26.
//

import AppKit

final class GhosttyTerminalView: NSView, TerminalCommands {
    private let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    private let padding: CGFloat = 8
    private let topPadding: CGFloat = 32

    private var terminal: GhosttyTerminal?
    private var renderState: GhosttyRenderState?
    private var rowIterator: GhosttyRenderStateRowIterator?
    private var rowCells: GhosttyRenderStateRowCells?

    private var ptyFD: Int32 = -1
    private var childPID: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var effects = ADBTerminalEffects()

    private var cols: UInt16 = 80
    private var rows: UInt16 = 24
    private var cellSize: CGSize = .zero
    private var hasStarted = false
    private var childExited = false
    private var lastOutput: String?
    private var outputBuffer: String = ""
    private var isCapturing: Bool = false

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        cellSize = Self.measureCell(font: font)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        readSource?.cancel()
        if let rowCells { ghostty_render_state_row_cells_free(rowCells) }
        if let rowIterator { ghostty_render_state_row_iterator_free(rowIterator) }
        if let renderState { ghostty_render_state_free(renderState) }
        if let terminal { ghostty_terminal_free(terminal) }
        adb_pty_close_child(ptyFD, childPID)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func layout() {
        super.layout()
        startIfNeeded()
        resizeTerminal()
    }

    private func resizeTerminal() {
        guard hasStarted, let terminal else { return }
        let oldCols = cols
        let oldRows = rows
        updateGridFromBounds()
        guard cols != oldCols || rows != oldRows else { return }

        ghostty_terminal_resize(terminal, cols, rows, cellPixelWidth, cellPixelHeight)
        if ptyFD >= 0 {
            adb_pty_resize(ptyFD, cols, rows, cellPixelWidth, cellPixelHeight)
        }

        effects.cols = cols
        effects.rows = rows
        effects.cell_width = cellPixelWidth
        effects.cell_height = cellPixelHeight

        updateRenderState()
        needsDisplay = true
    }

    private func updateRenderState() {
        guard let terminal, let renderState else { return }
        ghostty_render_state_update(renderState, terminal)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let renderState, let rowIterator, let rowCells else {
            NSColor.black.setFill()
            dirtyRect.fill()
            return
        }

        updateRenderState()

        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        ghostty_render_state_colors_get(renderState, &colors)

        nsColor(colors.background).setFill()
        bounds.fill()

        var iterator = rowIterator
        ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iterator)

        var y = topPadding
        while ghostty_render_state_row_iterator_next(iterator) {
            var cells = rowCells
            ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells)

            var x = padding
            while ghostty_render_state_row_cells_next(cells) {
                drawCell(cells, x: x, y: y, defaultColors: colors)
                x += cellSize.width
            }

            var clean = false
            ghostty_render_state_row_set(
                iterator,
                GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY,
                &clean
            )
            y += cellSize.height
        }

        drawCursor(renderState: renderState, colors: colors)
        drawExitBannerIfNeeded()

        var cleanState = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        ghostty_render_state_set(renderState, GHOSTTY_RENDER_STATE_OPTION_DIRTY, &cleanState)
    }

    private func drawCell(_ cells: GhosttyRenderStateRowCells,
                          x: CGFloat,
                          y: CGFloat,
                          defaultColors: GhosttyRenderStateColors) {
        let rect = CGRect(x: x, y: y, width: cellSize.width, height: cellSize.height)

        var bg = defaultColors.background
        let hasBG = ghostty_render_state_row_cells_get(
            cells,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR,
            &bg
        ) == GHOSTTY_SUCCESS
        if hasBG {
            nsColor(bg).setFill()
            rect.fill()
        }

        var len: UInt32 = 0
        ghostty_render_state_row_cells_get(
            cells,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN,
            &len
        )
        guard len > 0 else { return }

        var codepoints = [UInt32](repeating: 0, count: min(Int(len), 16))
        _ = codepoints.withUnsafeMutableBufferPointer { buffer in
            ghostty_render_state_row_cells_get(
                cells,
                GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF,
                buffer.baseAddress
            )
        }

        let text = String(String.UnicodeScalarView(codepoints.compactMap(UnicodeScalar.init)))
        guard !text.isEmpty else { return }

        var fg = defaultColors.foreground
        ghostty_render_state_row_cells_get(
            cells,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR,
            &fg
        )

        var style = GhosttyStyle()
        style.size = MemoryLayout<GhosttyStyle>.size
        ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)

        if style.inverse {
            let inverseBG = fg
            fg = bg
            nsColor(inverseBG).setFill()
            rect.fill()
        }

        let drawFont = style.bold ? NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .semibold) : font
        let attributes: [NSAttributedString.Key: Any] = [
            .font: drawFont,
            .foregroundColor: nsColor(fg)
        ]
        (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
    }

    private func drawCursor(renderState: GhosttyRenderState,
                            colors: GhosttyRenderStateColors) {
        var visible = false
        var inViewport = false
        ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &visible)
        ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &inViewport)
        guard visible && inViewport && window?.firstResponder === self else { return }

        var cx: UInt16 = 0
        var cy: UInt16 = 0
        ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &cx)
        ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &cy)

        let cursorColor = colors.cursor_has_value ? colors.cursor : colors.foreground
        nsColor(cursorColor).withAlphaComponent(0.45).setFill()
        CGRect(
            x: padding + CGFloat(cx) * cellSize.width,
            y: topPadding + CGFloat(cy) * cellSize.height,
            width: cellSize.width,
            height: cellSize.height
        ).fill()
    }

    private func drawExitBannerIfNeeded() {
        guard childExited else { return }
        let text = "[process exited]"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let rect = CGRect(x: 0, y: bounds.height - size.height - 12, width: bounds.width, height: size.height + 12)
        NSColor.black.withAlphaComponent(0.75).setFill()
        rect.fill()
        (text as NSString).draw(
            at: CGPoint(x: (bounds.width - size.width) / 2, y: rect.minY + 6),
            withAttributes: attributes
        )
    }

    override func insertText(_ insertString: Any) {
        let string = (insertString as? NSAttributedString)?.string ?? (insertString as? String) ?? ""
        writeToPTY(string)
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)):
            writeBytes([0x0D])
        case #selector(deleteBackward(_:)):
            writeBytes([0x7F])
        case #selector(insertTab(_:)):
            writeBytes([0x09])
        default:
            break
        }
    }

    @objc func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string) {
            writeToPTY(text)
        }
    }

    private var cellPixelWidth: UInt32 {
        UInt32(max(1, Int(cellSize.width)))
    }

    private var cellPixelHeight: UInt32 {
        UInt32(max(1, Int(cellSize.height)))
    }
}

// MARK: - Terminal Commands Conformance
extension GhosttyTerminalView {
    func sendCommand(_ command: String) async throws -> String {
        outputBuffer = ""
        isCapturing = true
        lastOutput = nil
        writeToPTY(command + "\n")
        
        let timeout: TimeInterval = 5.0
        let startTime = Date()
        var lastOutputTime = Date()
        var lastSeen: String? = nil
        
        while Date().timeIntervalSince(startTime) < timeout {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            
            if lastOutput != nil && lastOutput != lastSeen {
                lastSeen = lastOutput
                lastOutputTime = Date()
            }
            
            // if output hasn't changed for 0.5s, assume command is done
            if lastSeen != nil && Date().timeIntervalSince(lastOutputTime) > 0.5 {
                break
            }
        }
        
        isCapturing = false
        return outputBuffer.isEmpty ? "No Output" : outputBuffer
    }
    
    func captureScreenText() -> String? {
        guard let terminal else { return nil }
        
        var fmtOpts = GhosttyFormatterTerminalOptions()
        fmtOpts.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
        fmtOpts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        fmtOpts.trim = true
        
        var formatter: GhosttyFormatter?
        guard ghostty_formatter_terminal_new(nil, &formatter, terminal, fmtOpts) == GHOSTTY_SUCCESS,
              let formatter else { return nil }
        defer { ghostty_formatter_free(formatter) }
        
        var buf: UnsafeMutablePointer<UInt8>? = nil
        var len: Int = 0
        guard ghostty_formatter_format_alloc(formatter, nil, &buf, &len) == GHOSTTY_SUCCESS,
              let buf else { return nil }
        defer { ghostty_free(nil, buf, len) }
        
        return String(bytes: UnsafeBufferPointer(start: buf, count: len), encoding: .utf8)
    }
}

// MARK: - Start
extension GhosttyTerminalView {
    /**
     * Function Sets Needed Variables for a Terminal
     */
    private func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        
        updateGridFromBounds()
        
        var newTerminal: GhosttyTerminal?
        var newRenderState: GhosttyRenderState?
        var newRowIterator: GhosttyRenderStateRowIterator?
        var newRowCells: GhosttyRenderStateRowCells?
        
        let options = GhosttyTerminalOptions(
            cols: cols,
            rows: rows,
            max_scrollback: 4_000
        )
        
        let terminalResult = ghostty_terminal_new(nil, &newTerminal, options)
        let renderStateResult = ghostty_render_state_new(nil, &newRenderState)
        let rowIteratorResult = ghostty_render_state_row_iterator_new(nil, &newRowIterator)
        let rowCellsResult = ghostty_render_state_row_cells_new(nil, &newRowCells)
        
        guard terminalResult == GHOSTTY_SUCCESS,
              renderStateResult == GHOSTTY_SUCCESS,
              rowIteratorResult == GHOSTTY_SUCCESS,
              rowCellsResult == GHOSTTY_SUCCESS,
              let newTerminal,
              let newRenderState,
              let newRowIterator,
              let newRowCells
        else {
            return
        }
        
        /// Set Values
        terminal = newTerminal
        renderState = newRenderState
        rowIterator = newRowIterator
        rowCells = newRowCells
        
        ghostty_terminal_resize(newTerminal, cols, rows, cellPixelWidth, cellPixelHeight)
        
        var pid: pid_t = -1
        ptyFD = adb_pty_spawn(cols, rows, cellPixelWidth, cellPixelHeight, &pid)
        childPID = pid
        guard ptyFD >= 0 else {
            childExited = true
            needsDisplay = true
            return
        }
        
        effects = ADBTerminalEffects(
            pty_fd: ptyFD,
            cols: cols,
            rows: rows,
            cell_width: cellPixelWidth,
            cell_height: cellPixelHeight
        )
        adb_install_terminal_effects(newTerminal, &effects)
        
        readSource = DispatchSource.makeReadSource(fileDescriptor: ptyFD, queue: .main)
        readSource?.setEventHandler { [weak self] in
            self?.drainPTY()
        }
        readSource?.resume()
    }
    
    
    private func drainPTY() {
        guard let terminal, !childExited else { return }
        
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { rawBuffer in
                read(ptyFD, rawBuffer.baseAddress, rawBuffer.count)
            }
            if n > 0 {
                
                let raw = String(bytes: buffer.prefix(n), encoding: .utf8) ?? ""
                if isCapturing {
                    outputBuffer += raw
                }
                lastOutput = raw
                
                buffer.withUnsafeBufferPointer { rawBuffer in
                    ghostty_terminal_vt_write(terminal, rawBuffer.baseAddress, n)
                }
            } else if n == 0 || errno == EIO {
                childExited = true
                readSource?.cancel()
                break
            } else if errno == EAGAIN || errno == EINTR {
                break
            } else {
                childExited = true
                readSource?.cancel()
                break
            }
        }
        
        updateRenderState()
        needsDisplay = true
    }
}

// MARK: - Events
extension GhosttyTerminalView {
    /**
     * Handles Key Events
     */
    override func keyDown(
        with event: NSEvent
    ) {
        window?.makeFirstResponder(self)
        
        if handleControlKey(event) || handleSpecialKey(event) {
            return
        }
        
        interpretKeyEvents([event])
    }
    
    /**
     * Handles Scroll Wheel for scrolling
     */
    override func scrollWheel(
        with event: NSEvent
    ) {
        guard let terminal else { return }
        var scroll = GhosttyTerminalScrollViewport()
        scroll.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
        scroll.value.delta = event.scrollingDeltaY > 0 ? -3 : 3
        ghostty_terminal_scroll_viewport(terminal, scroll)
        updateRenderState()
        needsDisplay = true
    }
}

// MARK: - Keys
extension GhosttyTerminalView {
    /**
     * ANSI escape sequences
     * terminal doesnt know about this so we have to send these
     */
    private func handleSpecialKey(
        _ event: NSEvent
    ) -> Bool {
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return false }
        switch scalar.value {
            
            /// This is the Up/Down/Right/Left Arrow Keys
        case UInt32(NSUpArrowFunctionKey):
            writeToPTY("\u{1B}[A")
        case UInt32(NSDownArrowFunctionKey):
            writeToPTY("\u{1B}[B")
        case UInt32(NSRightArrowFunctionKey):
            writeToPTY("\u{1B}[C")
        case UInt32(NSLeftArrowFunctionKey):
            writeToPTY("\u{1B}[D")
            
            /// Beginning / End of Line (Home / End)
        case UInt32(NSHomeFunctionKey):
            writeToPTY("\u{1B}[H")
        case UInt32(NSEndFunctionKey):
            writeToPTY("\u{1B}[F")
            
            /// Page Up And Down
        case UInt32(NSPageUpFunctionKey):
            writeToPTY("\u{1B}[5~")
        case UInt32(NSPageDownFunctionKey):
            writeToPTY("\u{1B}[6~")
            /// Delete
        case UInt32(NSDeleteFunctionKey):
            writeToPTY("\u{1B}[3~")
        default:
            return false
        }
        return true
    }
    
    /**
     * Function Handles Control + Whatever Key
     */
    private func handleControlKey(
        _ event: NSEvent
    ) -> Bool {
        guard event.modifierFlags.contains(.control),
              let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else {
            return false
        }
        
        let value = scalar.value
        if value >= 65 && value <= 90 {
            writeBytes([UInt8(value - 64)])
            return true
        }
        if value >= 97 && value <= 122 {
            writeBytes([UInt8(value - 96)])
            return true
        }
        return false
    }
}

// MARK: - Writing
extension GhosttyTerminalView {
    private func writeToPTY(_ string: String) {
        guard ptyFD >= 0, let data = string.data(using: .utf8) else { return }
        data.withUnsafeBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress {
                adb_pty_write(ptyFD, baseAddress, rawBuffer.count)
            }
        }
    }
    
    private func writeBytes(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { buffer in
            if let baseAddress = buffer.baseAddress {
                adb_pty_write(ptyFD, baseAddress, buffer.count)
            }
        }
    }
}

// MARK: - Helpers
extension GhosttyTerminalView {
    /**
     * Function Determins a Width/Height for each cell
     * we use the letter M becuase its a good
     * representative monospace glyph
     */
    private static func measureCell(
        font: NSFont
    ) -> CGSize {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let size = ("M" as NSString).size(withAttributes: attributes)
        return CGSize(width: ceil(size.width), height: ceil(font.ascender - font.descender + font.leading))
    }
    
    /**
     * Function Sets Rows/Cols
     * which represents the actual view size in pixels/points
     */
    private func updateGridFromBounds() {
        let usableWidth = max(1, bounds.width - padding * 2)
        let usableHeight = max(1, bounds.height - topPadding - padding)
        cols = UInt16(max(1, Int(usableWidth / cellSize.width)))
        rows = UInt16(max(1, Int(usableHeight / cellSize.height)))
    }
    
    /**
     * Function Returns Color for
     * the type GhosttyColorRgb
     */
    private func nsColor(
        _ color: GhosttyColorRgb
    ) -> NSColor {
        NSColor(
            calibratedRed: CGFloat(color.r) / 255,
            green: CGFloat(color.g) / 255,
            blue: CGFloat(color.b) / 255,
            alpha: 1
        )
    }
}
