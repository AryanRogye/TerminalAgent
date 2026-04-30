//
//  TerminalCommands.swift
//  AgenticDebugging
//
//  Created by Aryan Rogye on 4/29/26.
//


/**
 * We Can Set this to a object so we can ask it to do certain things
 */
@MainActor
public protocol TerminalCommands: AnyObject {
    func sendCommand(_ command: String) async throws -> String
}
