// MapDataManagerTests.swift
// MeshtasticTests

import Testing
import Foundation
@testable import Meshtastic

/// Stubs `URLSession` responses for `MapDataManager.importFromRemote` without touching the network.
private final class GeoJSONStubURLProtocol: URLProtocol {
	nonisolated(unsafe) static var statusCode = 200
	nonisolated(unsafe) static var responseData: Data = Data()

	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		// Advertise `Content-Length` so `importFromRemote`'s streaming size guard can reject an oversized
		// body up front instead of iterating every byte of the stub payload.
		let headers = ["Content-Length": String(Self.responseData.count)]
		let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode, httpVersion: "HTTP/1.1", headerFields: headers)!
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: Self.responseData)
		client?.urlProtocolDidFinishLoading(self)
	}

	override func stopLoading() {}

	// Returns a stub-backed `URLSessionConfiguration` (not a full `URLSession`) so `importFromRemote`
	// always constructs the session with its `SSRFGuardDelegate` — the guard is never bypassed.
	static func makeConfiguration() -> URLSessionConfiguration {
		let config = URLSessionConfiguration.ephemeral
		config.protocolClasses = [GeoJSONStubURLProtocol.self]
		return config
	}
}

// Serialized: tests share mutable state on `GeoJSONStubURLProtocol` (its stubbed status/data are
// process-global, keyed by class not by request), so concurrent runs race and cross-contaminate.
@Suite("MapDataManager.importFromRemote", .serialized)
struct MapDataManagerImportFromRemoteTests {

	private let sampleGeoJSON = Data("""
	{ "type": "FeatureCollection", "features": [
		{ "type": "Feature", "geometry": { "type": "Polygon", "coordinates": [[[0, 0], [1, 0], [1, 1], [0, 0]]] },
		  "properties": { "fill": "#0080ff" } },
		{ "type": "Feature", "geometry": { "type": "Polygon", "coordinates": [[[2, 2], [3, 2], [3, 3], [2, 2]]] },
		  "properties": { "fill": "#00ff80" } }
	]}
	""".utf8)

	/// Deletes anything the test imported so repeated runs don't accumulate files in the real Documents
	/// directory — `MapDataManager` has no injectable storage root, so cleanup has to happen here.
	private func cleanUp(_ manager: MapDataManager, _ metadata: MapDataMetadata) async {
		try? await manager.deleteFile(metadata)
	}

	@Test func downloadsAndImportsValidGeoJSON() async throws {
		GeoJSONStubURLProtocol.statusCode = 200
		GeoJSONStubURLProtocol.responseData = sampleGeoJSON

		let manager = MapDataManager()
		let metadata = try await manager.importFromRemote(
			urlString: "https://example.com/coverage-\(UUID().uuidString).geojson",
			configuration: GeoJSONStubURLProtocol.makeConfiguration()
		)
		defer { Task { await cleanUp(manager, metadata) } }

		#expect(metadata.overlayCount == 2)
		#expect(metadata.format == "geojson")
	}

	@Test func throwsOnNonSuccessStatusCode() async throws {
		GeoJSONStubURLProtocol.statusCode = 404
		GeoJSONStubURLProtocol.responseData = Data()

		let manager = MapDataManager()
		await #expect(throws: Error.self) {
			try await manager.importFromRemote(
				urlString: "https://example.com/missing.geojson",
				configuration: GeoJSONStubURLProtocol.makeConfiguration()
			)
		}
	}

	@Test func throwsOnOversizedDownload() async throws {
		GeoJSONStubURLProtocol.statusCode = 200
		GeoJSONStubURLProtocol.responseData = Data(repeating: 0, count: 11 * 1024 * 1024) // > 10MB cap

		let manager = MapDataManager()
		await #expect(throws: MapDataError.self) {
			try await manager.importFromRemote(
				urlString: "https://example.com/huge.geojson",
				configuration: GeoJSONStubURLProtocol.makeConfiguration()
			)
		}
	}

	@Test func rejectsLocalFileURL() async throws {
		// The `importGeoJSON` deep link is untrusted, so `importFromRemote` must reject any non-http(s)
		// scheme outright — a `file://` URL can no longer fall through to the local-file read pipeline
		// (SSRF / local-file-read hardening). Legitimate local imports go via `processUploadedFile`.
		let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("local-\(UUID().uuidString).geojson")
		try sampleGeoJSON.write(to: tempURL)
		defer { try? FileManager.default.removeItem(at: tempURL) }

		let manager = MapDataManager()
		// Assert the *specific* rejection reason so this stays a security regression test: a `file://` URL
		// must be refused as a disallowed host, not pass for some unrelated map-data error.
		await #expect {
			try await manager.importFromRemote(urlString: tempURL.absoluteString, configuration: GeoJSONStubURLProtocol.makeConfiguration())
		} throws: { error in
			guard case MapDataError.disallowedHost = error else { return false }
			return true
		}
	}
}

/// Covers `MapDataManager.isDisallowedHost` — the SSRF host/IP denylist used by `importFromRemote`.
/// Only numeric IP literals and `localhost`/`.local` names are exercised so the suite stays hermetic
/// (those paths never hit DNS: `localhost`/`.local` short-circuit, and `getaddrinfo` resolves numeric
/// literals locally without a network round-trip).
@Suite("MapDataManager.isDisallowedHost")
struct MapDataManagerDisallowedHostTests {

	@Test("internal / non-routable hosts are blocked", arguments: [
		"localhost",
		"printer.local",
		"0.0.0.0",             // "this host"
		"127.0.0.1",           // loopback
		"10.0.0.1",            // RFC 1918
		"172.16.5.4",          // RFC 1918
		"192.168.1.1",         // RFC 1918
		"100.64.0.1",          // CGNAT
		"169.254.169.254",     // link-local / cloud metadata
		"192.0.2.5",           // TEST-NET-1 (RFC 5737)
		"198.51.100.5",        // TEST-NET-2 (RFC 5737)
		"203.0.113.5",         // TEST-NET-3 (RFC 5737)
		"224.0.0.1",           // multicast
		"[::1]",               // IPv6 loopback
		"[fe80::1]",           // IPv6 link-local
		"[fc00::1]",           // IPv6 unique-local
		"[::ffff:127.0.0.1]",  // IPv4-mapped loopback
		"[64:ff9b::a9fe:a9fe]" // NAT64-embedded 169.254.169.254
	])
	func blocksInternalHosts(_ host: String) {
		#expect(MapDataManager.isDisallowedHost(host), "expected \(host) to be blocked")
	}

	@Test("public IP literals are allowed", arguments: [
		"8.8.8.8",
		"1.1.1.1",
		"93.184.216.34",
		"[2606:4700:4700::1111]", // Cloudflare public IPv6 — guards against IPv6 being blanket-rejected
		"[2001:4860:4860::8888]"  // Google public IPv6
	])
	func allowsPublicHosts(_ host: String) {
		#expect(!MapDataManager.isDisallowedHost(host), "expected \(host) to be allowed")
	}
}

/// Covers `MapDataManager.importFromString` — the in-memory GeoJSON import path used by the
/// Site Planner native bridge (meshtastic/Meshtastic-Apple#2058).
@Suite("MapDataManager.importFromString", .serialized)
struct MapDataManagerImportFromStringTests {

	private let sampleGeoJSON = """
	{ "type": "FeatureCollection", "properties": { "name": "Coverage" }, "features": [
		{ "type": "Feature", "geometry": { "type": "Polygon", "coordinates": [[[0, 0], [1, 0], [1, 1], [0, 0]]] },
		  "properties": { "fill": "#0080ff" } },
		{ "type": "Feature", "geometry": { "type": "Polygon", "coordinates": [[[2, 2], [3, 2], [3, 3], [2, 2]]] },
		  "properties": { "fill": "#00ff80" } }
	]}
	"""

	private func cleanUp(_ manager: MapDataManager, _ metadata: MapDataMetadata) async {
		try? await manager.deleteFile(metadata)
	}

	@Test func importsValidGeoJSONString() async throws {
		let manager = MapDataManager()
		let metadata = try await manager.importFromString(sampleGeoJSON, name: "Site Alpha \(UUID().uuidString)")
		defer { Task { await cleanUp(manager, metadata) } }

		#expect(metadata.overlayCount == 2)
		#expect(metadata.format == "geojson")
	}

	@Test func enforcesGeojsonExtensionAndSanitizesName() async throws {
		let manager = MapDataManager()
		// A name with path separators must not escape the temp directory or lose the extension.
		let metadata = try await manager.importFromString(sampleGeoJSON, name: "a/b:c \(UUID().uuidString)")
		defer { Task { await cleanUp(manager, metadata) } }

		#expect(metadata.filename.hasSuffix(".geojson"))
		#expect(!metadata.filename.contains("/"))
		#expect(!metadata.filename.contains(":"))
	}

	@Test func throwsOnInvalidGeoJSON() async throws {
		let manager = MapDataManager()
		await #expect(throws: Error.self) {
			try await manager.importFromString("not json at all", name: "bad")
		}
	}

	@Test func throwsOnOversizedString() async throws {
		let manager = MapDataManager()
		let huge = String(repeating: "x", count: 11 * 1024 * 1024) // > 10MB cap
		await #expect(throws: MapDataError.self) {
			try await manager.importFromString(huge, name: "huge")
		}
	}
}
