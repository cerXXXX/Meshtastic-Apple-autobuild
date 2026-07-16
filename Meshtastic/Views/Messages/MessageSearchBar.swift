//
//  MessageSearchBar.swift
//  Meshtastic
//
//  Shared "find in conversation" bar for ChannelMessageList / UserMessageList.
//  Live match count + current index, previous/next navigation, and a close button.
//

import SwiftUI

struct MessageSearchBar: View {
	@Binding var query: String
	/// Total number of matches for the current query.
	let matchCount: Int
	/// Zero-based index of the currently-focused match, or -1 when there are none.
	let currentIndex: Int
	var onPrevious: () -> Void
	var onNext: () -> Void
	var onClose: () -> Void

	@FocusState private var focused: Bool

	var body: some View {
		HStack(spacing: 10) {
			HStack(spacing: 6) {
				Image(systemName: "magnifyingglass")
					.foregroundStyle(.secondary)
				TextField("Find in conversation", text: $query)
					.textFieldStyle(.plain)
					.autocorrectionDisabled()
					.submitLabel(.search)
					.focused($focused)
					.onSubmit(onNext)
				if !query.isEmpty {
					Button {
						query = ""
						focused = true
					} label: {
						Image(systemName: "xmark.circle.fill")
							.foregroundStyle(.secondary)
					}
					.buttonStyle(.borderless)
					.accessibilityLabel("Clear search")
				}
			}
			.padding(.horizontal, 10)
			.padding(.vertical, 7)
			.background(Color(.secondarySystemBackground))
			.clipShape(RoundedRectangle(cornerRadius: 10))

			if !query.isEmpty {
				Text(positionText)
					.font(.caption)
					.monospacedDigit()
					.foregroundStyle(.secondary)
					.accessibilityLabel(matchCount == 0 ? Text("No matches") : Text("Match \(currentIndex + 1) of \(matchCount)"))

				Button(action: onPrevious) {
					Image(systemName: "chevron.up")
				}
				.disabled(matchCount == 0)
				.accessibilityLabel("Previous match")

				Button(action: onNext) {
					Image(systemName: "chevron.down")
				}
				.disabled(matchCount == 0)
				.accessibilityLabel("Next match")
			}

			Button("Done", action: onClose)
				.font(.callout)
		}
		.buttonStyle(.borderless)
		.padding(.horizontal)
		.padding(.vertical, 8)
		.background(.bar)
		.onAppear { focused = true }
	}

	private var positionText: String {
		matchCount == 0 ? "0/0" : "\(currentIndex + 1)/\(matchCount)"
	}
}
