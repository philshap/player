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
                Button {
                    onChange?(star == rating ? 0 : star)
                } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .font(.caption)
                        .foregroundStyle(star <= rating ? Color.yellow : Color.gray.opacity(0.3))
                }
                .buttonStyle(.borderless)
            }
        }
    }
}
