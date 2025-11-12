//
//  Item.swift
//  BlackJackAppV1
//
//  Created by Trevor Dugan on 11/12/25.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
