// MARK: - FirmwareUpdateNotifier

import Foundation
import OSLog
import SwiftData

struct FirmwareUpdateNotificationCandidate {
	let nodeNum: Int64
	let deviceName: String?
	let platformioTarget: String?
	let supportsAppOTA: Bool
	let currentVersion: String?
	let latestStableVersion: String?
}

struct FirmwareUpdateNotificationSource {
	let nodeNum: Int64
	let deviceName: String?
	let platformioTarget: String?
	let architecture: String?
	let metadataVersion: String?
	let connectedVersion: String?
	let latestStableVersion: String?
}

enum FirmwareUpdateNotifier {
	static let target = "firmwareUpdates"
	static let path = "meshtastic:///settings/firmwareUpdates"
	private static let staleFirmwareAPIInterval: TimeInterval = 24 * 60 * 60

	static func candidate(from source: FirmwareUpdateNotificationSource) -> FirmwareUpdateNotificationCandidate {
		FirmwareUpdateNotificationCandidate(
			nodeNum: source.nodeNum,
			deviceName: source.deviceName,
			platformioTarget: source.platformioTarget,
			supportsAppOTA: FirmwareUpdateNotificationPolicy.supportsAppOTA(architecture: source.architecture),
			currentVersion: source.metadataVersion?.isEmpty == false ? source.metadataVersion : source.connectedVersion,
			latestStableVersion: source.latestStableVersion
		)
	}

	static func notification(
		for candidate: FirmwareUpdateNotificationCandidate,
		alreadyNotified: Set<String>
	) -> Notification? {
		guard let platformioTarget = candidate.platformioTarget,
		      candidate.supportsAppOTA,
		      let currentVersion = candidate.currentVersion,
		      let latestStableVersion = candidate.latestStableVersion,
		      FirmwareUpdateNotificationPolicy.shouldNotify(
			      nodeNum: candidate.nodeNum,
			      platformioTarget: platformioTarget,
			      currentVersion: currentVersion,
			      latestStableVersion: latestStableVersion,
			      alreadyNotified: alreadyNotified
		      ) else {
			return nil
		}

		let key = FirmwareUpdateNotificationPolicy.notificationKey(
			nodeNum: candidate.nodeNum,
			platformioTarget: platformioTarget,
			latestStableVersion: latestStableVersion
		)
		let displayName: String
		if let trimmedName = candidate.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedName.isEmpty {
			displayName = trimmedName
		} else {
			displayName = "Connected node"
		}
		let current = FirmwareUpdateNotificationPolicy.normalizedVersion(currentVersion)
		let latest = FirmwareUpdateNotificationPolicy.normalizedVersion(latestStableVersion)

		return Notification(
			id: key,
			title: "Firmware update available",
			subtitle: displayName,
			content: "\(displayName) is running \(current). Stable \(latest) is available.",
			target: target,
			path: path
		)
	}

	@MainActor
	static func notifyIfNeeded(accessoryManager: AccessoryManager) async {
		await refreshFirmwareDataIfStale()

		guard let nodeNum = accessoryManager.activeDeviceNum,
		      let node = getNodeInfo(id: nodeNum, context: accessoryManager.context),
		      let platformioTarget = node.myInfo?.pioEnv,
		      let hardware = hardwareSupportingAppOTA(platformioTarget: platformioTarget, context: accessoryManager.context) else {
			return
		}

		let candidate = candidate(from: FirmwareUpdateNotificationSource(
			nodeNum: node.num,
			deviceName: node.user?.longName ?? accessoryManager.activeConnection?.device.longName ?? accessoryManager.activeConnection?.device.name,
			platformioTarget: platformioTarget,
			architecture: hardware.architecture,
			metadataVersion: node.metadata?.firmwareVersion,
			connectedVersion: accessoryManager.connectedVersion,
			latestStableVersion: latestStableFirmwareVersion(context: accessoryManager.context)
		))

		guard let notification = notification(
			for: candidate,
			alreadyNotified: UserDefaults.firmwareUpdateNotificationKeySet
		) else {
			return
		}

		let localNotificationManager = LocalNotificationManager()
		localNotificationManager.notifications = [notification]
		localNotificationManager.schedule()
		UserDefaults.recordFirmwareUpdateNotificationKey(notification.id)
	}

	@MainActor
	private static func refreshFirmwareDataIfStale() async {
		guard UserDefaults.lastFirmwareAPIUpdate == .distantPast
			|| abs(UserDefaults.lastFirmwareAPIUpdate.timeIntervalSinceNow) > staleFirmwareAPIInterval else {
			return
		}

		do {
			try await MeshtasticAPI.shared.refreshFirmwareAPIData()
		} catch {
			Logger.services.warning("Failed to refresh firmware data before update notification check: \(error.localizedDescription, privacy: .public)")
		}
	}

	@MainActor
	private static func hardwareSupportingAppOTA(platformioTarget: String, context: ModelContext) -> DeviceHardwareEntity? {
		var descriptor = FetchDescriptor<DeviceHardwareEntity>(
			predicate: #Predicate { $0.platformioTarget == platformioTarget }
		)
		descriptor.fetchLimit = 1
		guard let hardware = try? context.fetch(descriptor).first,
		      FirmwareUpdateNotificationPolicy.supportsAppOTA(architecture: hardware.architecture) else {
			return nil
		}
		return hardware
	}

	@MainActor
	private static func latestStableFirmwareVersion(context: ModelContext) -> String? {
		let stableRawValue = ReleaseType.stable.rawValue
		var descriptor = FetchDescriptor<FirmwareReleaseEntity>(
			predicate: #Predicate { $0.releaseType == stableRawValue },
			sortBy: [
				SortDescriptor(\.versionMajor, order: .reverse),
				SortDescriptor(\.versionMinor, order: .reverse),
				SortDescriptor(\.versionPatch, order: .reverse)
			]
		)
		descriptor.fetchLimit = 1
		return try? context.fetch(descriptor).first?.versionId
	}
}
