import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // LedgerMobile contains the local SQLite cache and durable offline edit queue.
    // The self-hosted server is the backup; keep this directory out of iCloud backup.
    excludeLedgerDirectoryFromBackup()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func excludeLedgerDirectoryFromBackup() {
    do {
      let support = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      )[0]
      var ledgerDirectory = support.appendingPathComponent("LedgerMobile", isDirectory: true)
      try FileManager.default.createDirectory(
        at: ledgerDirectory,
        withIntermediateDirectories: true
      )
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try ledgerDirectory.setResourceValues(values)
    } catch {
      NSLog("Could not exclude ledger cache from backup: %@", String(describing: error))
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
