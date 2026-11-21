import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var localFilesChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let didLaunch = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    if didLaunch {
      excludeApplicationSupportFromBackup()
    }
    return didLaunch
  }

  private func excludeApplicationSupportFromBackup() {
    guard let supportDirectory = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first else {
      return
    }
    try? FileManager.default.createDirectory(
      at: supportDirectory,
      withIntermediateDirectories: true
    )
    try? supportDirectory.setResourceValue(
      true,
      forKey: .isExcludedFromBackupKey
    )
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "com.cwhale/local_files",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "openUrl" {
        guard
          let arguments = call.arguments as? [String: Any],
          let rawUrl = arguments["url"] as? String,
          let url = URL(string: rawUrl),
          ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          url.host != nil
        else {
          result(FlutterError(code: "INVALID_URL", message: "链接不是有效的 HTTP/HTTPS 地址。", details: nil))
          return
        }
        UIApplication.shared.open(url, options: [:]) { opened in
          if opened {
            result(nil)
          } else {
            result(FlutterError(code: "OPEN_URL_FAILED", message: "无法打开链接。", details: nil))
          }
        }
        return
      }

      guard call.method == "openWith" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard
        let arguments = call.arguments as? [String: Any],
        let path = arguments["path"] as? String,
        FileManager.default.fileExists(atPath: path)
      else {
        result(FlutterError(code: "FILE_NOT_FOUND", message: "本机文件不存在。", details: nil))
        return
      }
      self?.presentFile(at: URL(fileURLWithPath: path), result: result)
    }
    localFilesChannel = channel
  }

  private func presentFile(at url: URL, result: @escaping FlutterResult) {
    guard let presenter = topViewController else {
      result(FlutterError(code: "NO_VIEW", message: "无法显示系统打开菜单。", details: nil))
      return
    }
    let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    if let popover = activity.popoverPresentationController {
      popover.sourceView = presenter.view
      popover.sourceRect = CGRect(
        x: presenter.view.bounds.midX,
        y: presenter.view.bounds.midY,
        width: 0,
        height: 0
      )
      popover.permittedArrowDirections = []
    }
    presenter.present(activity, animated: true) {
      result(nil)
    }
  }

  private var topViewController: UIViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
    var controller = windows.first(where: \.isKeyWindow)?.rootViewController
    while let presented = controller?.presentedViewController {
      controller = presented
    }
    return controller
  }
}
