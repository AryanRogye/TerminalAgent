//
//  ChatViewModel.swift
//  AgenticDebugging
//
//  Created by Aryan Rogye on 4/29/26.
//

import Foundation
import MLXLMCommon
import MLXKit
import AppKit


public struct SendCommandToolArguments: Codable {
    public var command: String
    
    public init(command: String) {
        self.command = command
    }
}



@MainActor
@Observable
final class ChatViewModel {
    
    /**
     * All Messages
     */
    var messages: [any MessageRepresentable] = []
    
    var terminalCommands: TerminalCommands?
    
    /// Flag to know if we are currently sending a message or not
    var sendingMessage = false
    
    /// Error Related
    var error: String?
    var showError = false
    
    var lastInfo: GenerateCompletionInfo?
    
    /// Link Pattern lets us know if in a String what all of the urls are
    public static let linkPattern = #"\[([^\]]+)\]\((https?:\/\/[^\s\)]+)\)"#
    
    private var observationTask: Task<Void, Never>?
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    
    /**
     * Internal Service lets us talk to the MLX Model thats loaded
     */
    private let mlxChatService = MLXChatService()
    
    /**
     * Computed Property to know if the MLX model is
     * loaded or not
     */
    public var isLoaded: Bool {
        mlxChatService.isLoaded
    }
    
    public init() {}
    
    @MainActor
    deinit {
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
    }
    
    public func setTerminalCommands(_ t: TerminalCommands) {
        self.terminalCommands = t
    }
}

// MARK: - Memory
extension ChatViewModel {
    public func setMemoryLimit(limitInMB: Int) {
        Task {
            /// queue if we're busy
            while sendingMessage {
                 /// 0.1 sec
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            
            self.setMLXModelMemory(limitInMB: limitInMB)
        }
    }
    
    internal func setMLXModelMemory(limitInMB: Int) {
        mlxChatService.setMLXMemory(limitInMB: limitInMB)
    }
}

// MARK: - Generation Info
extension ChatViewModel {
    
    var promptProcessingTime: TimeInterval? {
        guard let lastInfo else { return nil }
        return lastInfo.promptTime
    }
    
    var tokenGenerationTime: TimeInterval? {
        guard let lastInfo else { return nil }
        return lastInfo.generateTime
    }
    
    var generationStopReason: String? {
        guard let lastInfo else { return nil }
        return switch lastInfo.stopReason {
        case .stop:
            "Generation Stopped Because EOS/unknown stop token was encountered"
        case .length:
            "Generation stopped because the configured max token limit was reached"
        case .cancelled:
            "Generation stopped due to explicit task cancellation or early stream termination"
        }
    }
}

// MARK: - Loading Model
extension ChatViewModel {
    static let systemPrompt = """
                              You are a Assistant in a Terminal, Your job
                              is to help the user with anything they may need
                              """
    
    
    /**
     * Loads The Model based off the URL provided
     * sets error flags if anything goes wrong
     */
    public func load(_ url: URL) async {
        do {
            try await mlxChatService.loadModel(
                at: url,
                defaultPrompt: Self.systemPrompt
            )
            setupObserversIfNeeded()
        } catch {
            self.error = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - Send Chat
extension ChatViewModel {
    
    /**
     * Function sends prompt to the loaded MLX Model
     */
    func send(_ prompt: String) {
        
        /// Make sure the model is loaded
        guard isLoaded else {
            error = "Model Not Loaded Yet"
            showError = true
            return
        }
        
        /// make sure we're not currently sending a message
        guard !sendingMessage else { return }
        
        /// Trim Prompt and making sure its not empty
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        /// set flag to true
        sendingMessage = true
        
        /// Creates Users Message
        self.addUserMessage(trimmed)
        
        let assistantID = UUID()
        
        Task {
            /// at end set the false
            defer {
                Task { @MainActor in
                    self.sendingMessage = false
                }
            }
            
            do {
                /**
                 * This removes the current assistant message you're about
                 * to stream into
                 */
                let modelMessages = messages
                    .filter { $0.id != assistantID }
                    .compactMap { $0 as? ChatMessage }
                    .map { ModelMessage(role: $0.role, content: $0.content) }
//                modelMessages.insert(ModelMessage(role: .system, content: Self.systemPrompt), at: 0)
                
                let _ = try await mlxChatService.getResponse(
                    messages: modelMessages,
                    tools: [
                        Self.sendCommandToTerminalTool,
                    ],
                    completion: { [weak self] (snippet: String) in
                        guard let self else { return }
                        Task { @MainActor in
                            self.appendToAssistantMessage(
                                id: assistantID,
                                chunk: snippet
                            )
                        }
                    },
                    toolcallCompletionHandler: { toolcallResponse in
                        Task { @MainActor in
                            try await self.handleToolCall(toolcallResponse)
                        }
                    },
                    infoCompletionHandler: { info in
                        Task { @MainActor in
                            self.lastInfo = info
                        }
                    }
                )
            } catch let e as MLXModelChatVideoModelError {
                await MainActor.run {
                    self.error = self.message(for: e)
                    self.showError = true
                    self.removeAssistantMessageIfEmpty(id: assistantID)
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.showError = true
                    self.removeAssistantMessageIfEmpty(id: assistantID)
                }
            }
        }
    }
}

// MARK: - Tools
extension ChatViewModel {
    /**
     This section is my prompts that I use to get a toolcall to activate, most of these require searching
     
     Prompt:
     What was the weather today in Chicago
     
     There was currently a new video by SideQuest Drew about exploring epsteins new island, can u look up the free version of the video?
     
     I’m trying to track down a specific JiDion video that includes a meta shout-out to Agent 00. In the video, JiDion actually anticipates that Agent will be reacting to the content on his stream. He looks directly at the camera and tells anyone watching via Agent’s ‘AMP’ stream that they should pause the reaction and go support the original upload on JiDion’s channel first. Does anyone have the link or know which video this was from?
     */
    static let sendCommandToTerminalTool: [String: any Sendable] = [
        "type": "function",
        "function": [
            "name": "sendCommandToTerminal",
            "description": "send command to terminal to get back a output",
            "parameters": [
                "type": "object",
                "properties": [
                    "command": [
                        "type": "string",
                        "description": "The command you want to run in the terminal"
                    ] as [String: any Sendable]
                ] as [String: any Sendable],
                "required": ["command"]
            ] as [String: any Sendable]
        ] as [String: any Sendable]
    ]
}

// MARK: - Handle Tool Calls
extension ChatViewModel {
    private func handleToolCall(
        _ response: ToolCallResponse,
        depth: Int = 0
    ) async throws {
        
        let maxDepth = 3
        
        guard depth < maxDepth else {
            return
        }
        
        let function = response.functionName
        
        /// This is important because we need the id to send back the content
        /// once we get it
        let message = ToolMessage(
            functionName: response.functionName,
            arguments: response.arguments
        )
        
        messages.append(message)
        
        switch function {
        case "sendCommandToTerminal":
            guard let terminalCommands else { break }
            if case .string(let command) = response.arguments["command"] {
                let result = SendCommandToolArguments(command: command)
                let response = try await terminalCommands.sendCommand(result.command)
                updateToolCall(id: message.id, result: response)
                try await respondToToolResult(
                    response,
                    label: command,
                    depth: depth
                )
            }
        default:
            break
        }
    }
    
    private func respondToToolResult(
        _ response: String,
        label: String,
        depth: Int
    ) async throws {
        print("")
        let message = ChatMessage(
            role: .user,
            content: """
                    The Terminal Output For \(label) is
                    \(response)
                    
                    Use this information to answer the question.
                    If it's not enough, you may search again.
                    If you need to open one of the links, call clickLink with the link number.
                    """
        )
        
        let assistantID = UUID()
        var modelMessages = messages
            .filter { $0.id != assistantID }
            .compactMap { $0 as? ChatMessage }
            .map { ModelMessage(role: $0.role, content: $0.content) }
        
        modelMessages.append(ModelMessage(role: message.role, content: message.content))
        
        let _ = try await mlxChatService.getResponse(
            messages: modelMessages,
            tools: [
                Self.sendCommandToTerminalTool,
            ],
            completion: { [weak self] (snippet: String) in
                guard let self else { return }
                Task { @MainActor in
                    self.appendToAssistantMessage(
                        id: assistantID,
                        chunk: snippet
                    )
                }
            },
            toolcallCompletionHandler: { toolcallResponse in
                Task { @MainActor in
                    try await self.handleToolCall(toolcallResponse, depth: depth + 1)
                }
            },
            infoCompletionHandler: { info in
                Task { @MainActor in
                    self.lastInfo = info
                }
            }
        )
    }
}

// MARK: - Observers
extension ChatViewModel {
    /**
     * Function sets up observed if their not already set
     */
    internal func setupObserversIfNeeded() {
        guard backgroundObserver == nil else { return }
        guard foregroundObserver == nil else { return }
        
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.mlxChatService.unload()
            }
        }
        
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                do {
                    try await self.mlxChatService.reload()
                } catch let e as MLXModelChatVideoModelError {
                    self.error = self.message(for: e)
                    self.showError = true
                } catch {
                    self.error = error.localizedDescription
                    self.showError = true
                }
            }
        }
    }

}

// MARK: - Helpers
extension ChatViewModel {
    /**
     * Function adds a message as a role user
     */
    private func addUserMessage(_ content: String) {
        let userMessage = ChatMessage(
            role: .user,
            content: content
        )
        messages.append(userMessage)
    }
    
    /**
     * Function Appends to assistant method if
     * the message doesnt exist yet, it creates it as we go
     * this is important
     */
    private func appendToAssistantMessage(id: UUID, chunk: String) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            let message = messages[index]
            if let m = message as? ChatMessage {
                m.content += chunk
                messages[index] = m
            }
        } else {
            messages.append(
                ChatMessage(
                    id: id,
                    role: .assistant,
                    content: chunk
                )
            )
        }
    }
    
    /**
     * Updates the tool call UI after it's triggered.
     *
     * Normally, a tool call just shows that it was invoked.
     * This allows us to:
     * 1. Display the initial tool call
     * 2. Wait for the async operation to complete
     * 3. Update the UI with the result afterward
     *
     * Makes the interaction feel smoother and more dynamic.
     */
    private func updateToolCall(id: UUID, result: String) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            if let toolCall = messages[index] as? ToolMessage {
                toolCall.result = result
                messages[index] = toolCall
                print("Updated Tool Call Result: \(result)")
            }
        }
    }
    
    /**
     * Removes Assistant Message If Empty
     */
    private func removeAssistantMessageIfEmpty(id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let message = messages[index]
        if let m = message as? ChatMessage {
            if m.content.isEmpty {
                messages.remove(at: index)
            }
        }
    }

    /**
     * Function Handles Errors For Us
     */
    internal func message(for error: MLXModelChatVideoModelError) -> String {
        switch error {
        case .modelDoesntExist:
            return "Model Doesnt Exist"
        case .errorWhileLoadingContainer(let string):
            return "Error While Loading Container: \(string)"
        case .containerNotConfigured:
            return "Container Not Configured"
        case .cantGenerateResponseNotLoaded:
            return "Not Loaded Cant Generate Response"
        case .cantReload(let reason):
            return "Cant Reload: \(reason)"
        }
    }
}
