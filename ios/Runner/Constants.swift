//
//  DocumentScannerConstants.swift
//  Runner
//
//  Created by Pedro Santos on 07/10/25.
//

import Foundation

struct Constants {
    static let stabilityDelay: TimeInterval = 2.0 // O tempo de confirmação em segundos (2 segundos)
    static let stabilityThreshold: CGFloat = 0.01 // Movimento máximo permitido (1% da tela)
    static let commandChannelName = "document_scanner"
    static let eventChannelName = "document_scanner_events"
}
