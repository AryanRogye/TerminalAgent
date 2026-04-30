//
//  Toolbar.swift
//  ComfyPilot
//
//  Created by Aryan Rogye on 4/24/26.
//

import SwiftUI
import MLXKit

struct Toolbar: ToolbarContent {
    
    @Bindable var loaderService : ModelLoaderService
    
    var body: some ToolbarContent {
        
        // CENTER / STATUS area
        ToolbarItemGroup(placement: .status) {
            NavigationLink(
                destination: ModelsInfoView(loaderService: loaderService)
            ) {
                Image(systemName: "arrow.down.circle")
            }
        }
    }
}
