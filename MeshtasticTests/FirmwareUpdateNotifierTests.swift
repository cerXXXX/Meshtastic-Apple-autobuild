import Foundation
import Testing

@testable import Meshtastic

@Suite("Firmware update notifier")
struct FirmwareUpdateNotifierTests {

	@Test func notificationPayloadRoutesToFirmwareUpdates() {
		let notification = FirmwareUpdateNotifier.notification(for: FirmwareUpdateNotificationCandidate(
			nodeNum: 0x1234,
			deviceName: "Meshtastic c058",
			platformioTarget: "tbeam-s3-core",
			supportsAppOTA: true,
			currentVersion: "2.7.26.54e0d8d",
			latestStableVersion: "v2.8.0"
		),
			alreadyNotified: []
		)

		#expect(notification?.id == "firmware-update-notified:4660:tbeam-s3-core:2.8.0")
		#expect(notification?.title == "Firmware update available")
		#expect(notification?.subtitle == "Meshtastic c058")
		#expect(notification?.content.contains("2.7.26") == true)
		#expect(notification?.content.contains("2.8.0") == true)
		#expect(notification?.target == "firmwareUpdates")
		#expect(notification?.path == "meshtastic:///settings/firmwareUpdates")
	}

	@Test func notificationReturnsNilWhenMetadataIsMissing() {
		#expect(FirmwareUpdateNotifier.notification(for: FirmwareUpdateNotificationCandidate(
			nodeNum: 0x1234,
			deviceName: "Meshtastic c058",
			platformioTarget: nil,
			supportsAppOTA: true,
			currentVersion: "2.7.26",
			latestStableVersion: "v2.8.0"
		),
			alreadyNotified: []
		) == nil)
		#expect(FirmwareUpdateNotifier.notification(for: FirmwareUpdateNotificationCandidate(
			nodeNum: 0x1234,
			deviceName: "Meshtastic c058",
			platformioTarget: "tbeam-s3-core",
			supportsAppOTA: true,
			currentVersion: nil,
			latestStableVersion: "v2.8.0"
		),
			alreadyNotified: []
		) == nil)
		#expect(FirmwareUpdateNotifier.notification(for: FirmwareUpdateNotificationCandidate(
			nodeNum: 0x1234,
			deviceName: "Meshtastic c058",
			platformioTarget: "tbeam-s3-core",
			supportsAppOTA: true,
			currentVersion: "2.7.26",
			latestStableVersion: nil
		),
			alreadyNotified: []
		) == nil)
	}

	@Test func notificationReturnsNilWhenAppCannotOTAThisHardware() {
		let notification = FirmwareUpdateNotifier.notification(for: FirmwareUpdateNotificationCandidate(
			nodeNum: 0x1234,
			deviceName: "RP2040 node",
			platformioTarget: "rak11310",
			supportsAppOTA: false,
			currentVersion: "2.7.26",
			latestStableVersion: "v2.8.0"
		),
			alreadyNotified: []
		)

		#expect(notification == nil)
	}

	@Test func notificationReturnsNilWhenAlreadyNotified() {
		let key = FirmwareUpdateNotificationPolicy.notificationKey(
			nodeNum: 0x1234,
			platformioTarget: "tbeam-s3-core",
			latestStableVersion: "v2.8.0"
		)

		let notification = FirmwareUpdateNotifier.notification(for: FirmwareUpdateNotificationCandidate(
			nodeNum: 0x1234,
			deviceName: "Meshtastic c058",
			platformioTarget: "tbeam-s3-core",
			supportsAppOTA: true,
			currentVersion: "2.7.26",
			latestStableVersion: "v2.8.0"
		),
			alreadyNotified: [key]
		)

		#expect(notification == nil)
	}

	@Test func candidateUsesMetadataVersionBeforeConnectedFallback() {
		let metadataCandidate = FirmwareUpdateNotifier.candidate(from: FirmwareUpdateNotificationSource(
			nodeNum: 0x1234,
			deviceName: "Meshtastic c058",
			platformioTarget: "tbeam-s3-core",
			architecture: "esp32-s3",
			metadataVersion: "2.7.25",
			connectedVersion: "2.7.26.54e0d8d",
			latestStableVersion: "v2.8.0"
		))
		let fallbackCandidate = FirmwareUpdateNotifier.candidate(from: FirmwareUpdateNotificationSource(
			nodeNum: 0x1234,
			deviceName: "Meshtastic c058",
			platformioTarget: "tbeam-s3-core",
			architecture: "esp32-s3",
			metadataVersion: nil,
			connectedVersion: "2.7.26.54e0d8d",
			latestStableVersion: "v2.8.0"
		))

		#expect(metadataCandidate.currentVersion == "2.7.25")
		#expect(metadataCandidate.supportsAppOTA)
		#expect(fallbackCandidate.currentVersion == "2.7.26.54e0d8d")
	}
}
