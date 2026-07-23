//
//  AccessoryManagerConnectStopsDiscoveryTests.swift
//  MeshtasticTests
//
//  Companion to AccessoryManagerScanDuringPairingTests.swift, which covers the
//  appDidBecomeActive() guard directly. This suite drives the real
//  AccessoryManager.connect(to:) pipeline (AccessoryManager+Connect.swift's SequentialSteps)
//  through Step 0 and Step 1, using a minimal mock Transport/Connection pair, to verify
//  Step 0's stopDiscovery() call actually runs — and discovery is actually off — by the time
//  Step 1 hands control to the connection, on both the first attempt and a retry. This closes
//  the "verified by code inspection, not by test" gap noted in the #2183 review.
//

import Foundation
import MeshtasticProtobufs
import Testing

@testable import Meshtastic

/// Records, from inside the mock connection's `connect()`, whether `AccessoryManager.discoveryTask`
/// was nil (i.e. discovery already stopped by Step 0) at the moment Step 1 handed off. An actor
/// so it's safe to mutate from the mock connection actor's isolation.
actor DiscoveryStateRecorder {
	private(set) var discoveryTaskWasNilAtConnect: [Bool] = []

	func record(_ wasNil: Bool) {
		discoveryTaskWasNilAtConnect.append(wasNil)
	}
}

/// The minimum `Transport` conformance to satisfy `AccessoryManager.connect(to:)`'s
/// `transportForType` lookup and Step 8's `requiresPeriodicHeartbeat` read. `connect(to:)` itself
/// is never called — tests inject a `MockPairingConnection` directly via `withConnection:`.
final class MockBLETransportForConnectTests: Transport, @unchecked Sendable {
	let type: TransportType = .ble
	var status: TransportStatus { get async { .ready } }
	let requiresPeriodicHeartbeat = false
	let supportsManualConnection = false

	func discoverDevices() async -> AsyncStream<DiscoveryEvent> {
		AsyncStream { _ in }
	}

	func connect(to device: Device) async throws -> any Connection {
		throw AccessoryError.connectionFailed("MockBLETransportForConnectTests.connect(to:) should not be called; tests inject withConnection:")
	}

	func device(forManualConnection: String) -> Device? { nil }
	func manuallyConnect(toDevice: Device) async throws {}
}

/// A `Connection` whose `connect()` records whether `AccessoryManager.discoveryTask` was nil at
/// call time, then always fails — the pipeline never needs to progress past Step 1 to answer the
/// "was discovery stopped before Step 1 handed off" question this suite is testing.
actor MockPairingConnection: Connection {
	let type: TransportType = .ble
	var isConnected: Bool = false

	private weak var accessoryManager: AccessoryManager?
	private let recorder: DiscoveryStateRecorder

	init(accessoryManager: AccessoryManager, recorder: DiscoveryStateRecorder) {
		self.accessoryManager = accessoryManager
		self.recorder = recorder
	}

	func connect() async throws -> AsyncStream<ConnectionEvent> {
		let discoveryTaskWasNil = await accessoryManager?.discoveryTask == nil
		await recorder.record(discoveryTaskWasNil)
		throw AccessoryError.connectionFailed("MockPairingConnection always fails — discovery-timing probe only")
	}

	func send(_ data: ToRadio) async throws {}
	func disconnect(withError: Error?, shouldReconnect: Bool) async throws {}
	func drainPendingPackets() async throws {}
	func startDrainPendingPackets() throws {}
	func appDidEnterBackground() {}
	func appDidBecomeActive() {}
}

@MainActor
@Suite("AccessoryManager.connect(to:) stops discovery before Step 1")
struct AccessoryManagerConnectStopsDiscoveryTests {

	private func makeDevice() -> Device {
		Device(id: UUID(), name: "Mock Radio", transportType: .ble, identifier: UUID().uuidString)
	}

	@Test func stopsDiscoveryBeforeTheFirstConnectAttempt() async throws {
		let manager = AccessoryManager(transports: [MockBLETransportForConnectTests()])
		manager.startDiscovery()
		#expect(manager.discoveryTask != nil)

		let recorder = DiscoveryStateRecorder()
		let device = makeDevice()
		let connection = MockPairingConnection(accessoryManager: manager, recorder: recorder)

		// A single attempt (retries: 1) is enough to answer "was discovery off by Step 1" —
		// no need to pay the retry delay here. AccessoryManager.connect(to:) catches its own
		// step failures internally (surfacing them via lastConnectionError) rather than
		// rethrowing, so it does not throw here even though Step 1 always fails.
		try await manager.connect(
			to: device,
			withConnection: connection,
			wantConfig: false,
			wantDatabase: false,
			versionCheck: false,
			retries: 1
		)

		#expect(manager.lastConnectionError != nil)
		let observed = await recorder.discoveryTaskWasNilAtConnect
		#expect(observed == [true])
	}

	@Test func stopsDiscoveryBeforeEveryRetriedConnectAttempt() async throws {
		let manager = AccessoryManager(transports: [MockBLETransportForConnectTests()])
		manager.startDiscovery()

		let recorder = DiscoveryStateRecorder()
		let device = makeDevice()
		let connection = MockPairingConnection(accessoryManager: manager, recorder: recorder)

		// retries: 2 forces exactly one retry (SequentialSteps.run() iterates 0..<maxRetries),
		// so Step 0 — and its stopDiscovery() call — runs twice: once for the first attempt,
		// once after closeConnection() re-arms discovery ahead of the retry. Same non-throwing
		// note as above applies here.
		try await manager.connect(
			to: device,
			withConnection: connection,
			wantConfig: false,
			wantDatabase: false,
			versionCheck: false,
			retries: 2
		)

		#expect(manager.lastConnectionError != nil)
		let observed = await recorder.discoveryTaskWasNilAtConnect
		#expect(observed == [true, true])
	}
}
