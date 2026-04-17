//
//  RatingView.swift
//  player
//

import SwiftUI

/// A clickable 5-star rating control. Click a star to set rating; click the same star to clear.
struct RatingView: View {
    let rating: Int
    var onChange: ((Int) -> Void)?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundStyle(star <= rating ? .yellow : .tertiary)
                    .onTapGesture {
                        onChange?(star == rating ? 0 : star)
                    }
            }
        }
    }
}
