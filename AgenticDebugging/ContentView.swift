//
//  ContentView.swift
//  AgenticDebugging
//
//  Created by Aryan Rogye on 4/29/26.
//

import SwiftUI
import MLXKit


struct ContentView: View {
    
    @State private var chatVM = ChatViewModel()
    @State private var loaderService = ModelLoaderService(selectFirst: true)
    @State private var sendingMessage = false
    @State private var loading = false
    
    var body: some View {
        HSplitView {
            GhosttyTerminalRepresentable { t in
                chatVM.setTerminalCommands(t)
            }
            .frame(minWidth: 720, minHeight: 420)
            
            ChatSidebar(vm: chatVM, sendingMessage: $sendingMessage)
                .frame(minWidth: 200)
                .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
        .ignoresSafeArea()
        .toolbar{ Toolbar(loaderService: loaderService) }
        .task {
            if let selected = loaderService.selected {
                loadModel(model: selected)
            }
        }
        .onChange(of: loaderService.selected) { _, newValue in
            if let newValue {
                loadModel(model: newValue)
            }
        }
    }
    
    /**
     * Helper to load model once a model is selected
     */
    private func loadModel(model: MLXChatModel) {
        if loading { return }
        
        Task {
            loading = true
            defer { loading = false }
            
            await chatVM.load(model.url)
        }
    }
}

#Preview {
    ContentView()
}
