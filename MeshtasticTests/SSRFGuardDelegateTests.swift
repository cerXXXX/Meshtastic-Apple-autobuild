// SSRFGuardDelegateTests.swift
// MeshtasticTests

import Testing
import Foundation
@testable import Meshtastic

/// Verifies `SSRFGuardDelegate.willPerformHTTPRedirection` — the reliable SSRF control that stops a
/// public, allow-listed URL from being redirected (`302`) onto an internal host. Hermetic: only
/// numeric IP literals / hostless URLs are used, so no DNS/network is touched (the delegate calls the
/// completion handler synchronously, so the captured value is available immediately after the call).
@Suite("SSRFGuardDelegate.willPerformHTTPRedirection")
struct SSRFGuardDelegateRedirectTests {

	/// Drives the redirect delegate method and returns whether the redirect was followed, and to what.
	private func performRedirect(to target: String) -> (called: Bool, followed: URLRequest?) {
		let delegate = SSRFGuardDelegate()
		let task = URLSession.shared.dataTask(with: URL(string: "https://93.184.216.34/")!)
		defer { task.cancel() }
		let response = HTTPURLResponse(
			url: URL(string: "https://93.184.216.34/")!,
			statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target]
		)!
		let newRequest = URLRequest(url: URL(string: target)!)

		var called = false
		var followed: URLRequest?
		delegate.urlSession(
			URLSession.shared, task: task,
			willPerformHTTPRedirection: response, newRequest: newRequest
		) { request in
			called = true
			followed = request
		}
		return (called, followed)
	}

	@Test("refuses a 302 redirect to loopback")
	func refusesRedirectToLoopback() {
		let result = performRedirect(to: "http://127.0.0.1:9000/ssrf")
		#expect(result.called)              // the completion handler is always invoked
		#expect(result.followed == nil)     // …with nil → the internal redirect is NOT followed
	}

	@Test("refuses a 302 redirect to cloud metadata / link-local")
	func refusesRedirectToLinkLocal() {
		let result = performRedirect(to: "http://169.254.169.254/latest/meta-data/")
		#expect(result.called)
		#expect(result.followed == nil)
	}

	@Test("refuses a 302 redirect to a private LAN address")
	func refusesRedirectToPrivateLAN() {
		let result = performRedirect(to: "http://192.168.1.1/admin")
		#expect(result.called)
		#expect(result.followed == nil)
	}

	@Test("follows a 302 redirect to a public host")
	func followsRedirectToPublicHost() {
		let result = performRedirect(to: "http://8.8.8.8/overlay.geojson")
		#expect(result.called)
		#expect(result.followed?.url?.absoluteString == "http://8.8.8.8/overlay.geojson")
	}

	@Test("a freshly-created delegate has not flagged a disallowed peer")
	func peerFlagDefaultsFalse() {
		#expect(SSRFGuardDelegate().connectedToDisallowedPeer == false)
	}
}
