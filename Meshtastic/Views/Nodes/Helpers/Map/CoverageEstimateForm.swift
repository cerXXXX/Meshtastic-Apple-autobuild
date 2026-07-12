//
//  CoverageEstimateForm.swift
//  Meshtastic
//
//  The estimate form for an in-app Site Planner coverage run. Mirrors the
//  planner's `Site Parameters` panels — Site / Transmitter → Receiver →
//  Simulation Options → Display, with Transmitter + Display open and the rest
//  collapsed. Submitting drives `CoverageEstimateRunner` (headless WebView +
//  bridge) and, on success, imports the styled GeoJSON as a map overlay.
//
//  See meshtastic/Meshtastic-Apple#2058.
//

import SwiftUI
import CoreLocation

/// Seed for presenting the estimate form: the prefilled parameters plus the
/// coordinates available as one-tap location shortcuts.
struct CoverageEstimateSeed: Identifiable {
	let id = UUID()
	var parameters: SitePlannerParameters
	/// The selected node's coordinate, when launched from a node.
	var nodeCoordinate: CLLocationCoordinate2D?
	/// The current map centre, when launched from the map toolbar.
	var mapCenter: CLLocationCoordinate2D?
}

struct CoverageEstimateForm: View {

	let seed: CoverageEstimateSeed
	@ObservedObject var runner: CoverageEstimateRunner

	@Environment(\.dismiss) private var dismiss

	@State private var params: SitePlannerParameters
	@State private var transmitterExpanded = true
	@State private var receiverExpanded = false
	@State private var simulationExpanded = false
	@State private var displayExpanded = true
	@State private var errorMessage: String?

	init(seed: CoverageEstimateSeed, runner: CoverageEstimateRunner) {
		self.seed = seed
		self.runner = runner
		_params = State(initialValue: seed.parameters)
	}

	private var deviceLocation: CLLocationCoordinate2D? {
		LocationsHandler.currentLocation
	}

	var body: some View {
		NavigationStack {
			Form {
				transmitterSection
				receiverSection
				simulationSection
				displaySection
			}
			.navigationTitle("Estimate Coverage")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") {
						runner.reset()
						dismiss()
					}
				}
				ToolbarItem(placement: .confirmationAction) {
					Button("Estimate") {
						runner.start(params: params)
					}
					.disabled(!params.isValid || runner.isRunning)
				}
			}
			.overlay {
				if runner.isRunning {
					estimatingOverlay
				}
			}
			.onDisappear {
				// Tear down a still-running headless run if the sheet is swipe-dismissed. Safe on the
				// success path too — the import already published its result before `dismiss()`.
				runner.reset()
			}
			.onChange(of: runner.state) { _, newState in
				switch newState {
				case .imported:
					dismiss()
				case let .failed(message):
					errorMessage = message
				default:
					break
				}
			}
			.alert("Coverage estimate failed", isPresented: Binding(
				get: { errorMessage != nil },
				set: { if !$0 { errorMessage = nil } }
			)) {
				Button("OK", role: .cancel) { runner.reset() }
			} message: {
				Text(errorMessage ?? "")
			}
		}
	}

	// MARK: - Sections

	private var transmitterSection: some View {
		Section {
			DisclosureGroup(isExpanded: $transmitterExpanded) {
				TextField("Site name", text: $params.name)
					.accessibilityLabel("Site name")

				locationShortcuts

				labeledNumber("Latitude", value: $params.latitude)
				labeledNumber("Longitude", value: $params.longitude)
				labeledNumber("Transmit power (W)", value: $params.txPowerWatts)
				labeledNumber("Frequency (MHz)", value: $params.txFrequencyMHz)
				labeledNumber("Antenna height (m)", value: $params.txHeightMeters)
				labeledNumber("Antenna gain (dBi)", value: $params.txGainDBi)
			} label: {
				Label("Site / Transmitter", systemImage: "antenna.radiowaves.left.and.right")
			}
		}
	}

	private var receiverSection: some View {
		Section {
			DisclosureGroup(isExpanded: $receiverExpanded) {
				labeledNumber("Sensitivity (dBm)", value: $params.rxSensitivityDBm)
			} label: {
				Label("Receiver", systemImage: "dot.radiowaves.left.and.right")
			}
		}
	}

	private var simulationSection: some View {
		Section {
			DisclosureGroup(isExpanded: $simulationExpanded) {
				labeledNumber("Max range (km)", value: $params.maxRangeKm)
				Toggle("High-resolution terrain", isOn: $params.highResolution)
					.onChange(of: params.highResolution) { _, _ in
						// High-res caps the range at 70 km — clamp so the value stays valid.
						let bounds = params.maxRangeBounds
						params.maxRangeKm = min(max(params.maxRangeKm, bounds.lowerBound), bounds.upperBound)
					}
			} label: {
				Label("Simulation Options", systemImage: "slider.horizontal.3")
			}
		}
	}

	private var displaySection: some View {
		Section {
			DisclosureGroup(isExpanded: $displayExpanded) {
				Picker("Palette", selection: $params.colorScale) {
					ForEach(SitePlannerColorScale.allCases) { scale in
						Text(scale.displayName).tag(scale)
					}
				}
			} label: {
				Label("Display", systemImage: "paintpalette")
			}
		}
	}

	// MARK: - Location shortcuts

	@ViewBuilder private var locationShortcuts: some View {
		let hasShortcuts = deviceLocation != nil || seed.nodeCoordinate != nil || seed.mapCenter != nil
		if hasShortcuts {
			VStack(alignment: .leading, spacing: 6) {
				Text("Set coordinates from")
					.font(.caption)
					.foregroundStyle(.secondary)
				HStack(spacing: 8) {
					if let device = deviceLocation {
						shortcutButton("My Location", systemImage: "location.fill") { apply(device) }
					}
					if let node = seed.nodeCoordinate {
						shortcutButton("Node", systemImage: "flipphone") { apply(node) }
					}
					if let center = seed.mapCenter {
						shortcutButton("Map Center", systemImage: "scope") { apply(center) }
					}
				}
				.buttonStyle(.bordered)
			}
		}
	}

	/// A compact equal-width shortcut cell: icon over a single-line label, so long titles
	/// ("My Location", "Map Center") don't wrap or hyphenate in the three-across row.
	private func shortcutButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			VStack(spacing: 4) {
				Image(systemName: systemImage)
					.font(.body)
				Text(title)
					.font(.caption2)
					.lineLimit(1)
					.minimumScaleFactor(0.75)
			}
			.frame(maxWidth: .infinity)
			.padding(.vertical, 4)
		}
		.accessibilityLabel(Text(title))
		.accessibilityHint("Fills the transmitter coordinates.")
	}

	private func apply(_ coordinate: CLLocationCoordinate2D) {
		params.latitude = coordinate.latitude
		params.longitude = coordinate.longitude
	}

	// MARK: - Helpers

	private func labeledNumber(_ title: LocalizedStringKey, value: Binding<Double>) -> some View {
		HStack {
			Text(title)
			Spacer()
			TextField("", value: value, format: .number)
				.keyboardType(.numbersAndPunctuation)
				.multilineTextAlignment(.trailing)
				.frame(maxWidth: 140)
				.accessibilityLabel(Text(title))
		}
	}

	private var estimatingOverlay: some View {
		ZStack {
			Color(.systemBackground).opacity(0.85).ignoresSafeArea()
			VStack(spacing: 16) {
				ProgressView()
					.controlSize(.large)
				Text("Estimating coverage…")
					.font(.headline)
				Button("Cancel") {
					runner.reset()
				}
				.buttonStyle(.bordered)
			}
			.padding(24)
			.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
		}
	}
}
