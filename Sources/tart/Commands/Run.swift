import ArgumentParser
import Cocoa
import Dispatch
import SwiftUI
import Virtualization
import Sentry

var vm: VM?

struct IPNotFound: Error {
}

struct Run: AsyncParsableCommand {
  static var configuration = CommandConfiguration(abstract: "Run a VM")

  @Argument(help: "VM name")
  var name: String

  @Flag(help: ArgumentHelp(
    "Don't open a UI window.",
    discussion: "Useful for integrating Tart VMs into other tools.\nUse `tart ip` in order to get an IP for SSHing or VNCing into the VM."))
  var noGraphics: Bool = false

  @Flag(help: ArgumentHelp(
    "Open serial console in /dev/ttySXX",
    discussion: "Useful for debugging Linux Kernel."))
  var serial: Bool = false

  @Option(help: ArgumentHelp(
    "Attach an externally created serial console",
    discussion: "Alternative to `--serial` flag for programmatic integrations."
  ))
  var serialPath: String?

  @Flag(help: "Force open a UI window, even when VNC is enabled.")
  var graphics: Bool = false

  @Flag(help: "Boot into recovery mode")
  var recovery: Bool = false

  @Flag(help: "Boot into DFU mode") 
  var dfu: Bool = false
    
  @Flag(help: ArgumentHelp(
    "Halt on fatal error",
    discussion: "Requires host to be macOS 14.0 (Sonoma) or newer."))
  var stopOnFatalError: Bool = false

  @Flag(help: "Halt when panicked") 
  var stopOnPanic: Bool = false

  @Flag(help: "Halt when loading iBootStage1") 
  var stopInIBootStage1: Bool = false

  @Flag(help: "Halt when loading iBootStage2") 
  var stopInIBootStage2: Bool = false

  @Flag(help: ArgumentHelp(
    "Use screen sharing instead of the built-in UI.",
    discussion: "Useful since Screen Sharing supports copy/paste, drag and drop, etc.\n"
      + "Note that Remote Login option should be enabled inside the VM."))
  var vnc: Bool = false

  @Flag(help: ArgumentHelp(
    "Use Virtualization.Framework's VNC server instead of the build-in UI.",
    discussion: "Useful since this type of VNC is available in recovery mode and in macOS installation.\n"
      + "Note that this feature is experimental and there may be bugs present when using VNC."))
  var vncExperimental: Bool = false

  @Option(help: ArgumentHelp("""
  Additional disk attachments with an optional read-only specifier\n(e.g. --disk=\"disk.bin\" --disk=\"ubuntu.iso:ro\")
  """, discussion: """
  Learn how to create a disk image using Disk Utility here:
  https://support.apple.com/en-gb/guide/disk-utility/dskutl11888/mac
  """, valueName: "path[:ro]"))
  var disk: [String] = []

  @Option(name: [.customLong("rosetta")], help: ArgumentHelp(
    "Attaches a Rosetta share to the guest Linux VM with a specific tag (e.g. --rosetta=\"rosetta\")",
    discussion: """
    Requires host to be macOS 13.0 (Ventura) with Rosetta installed. The latter can be done
    by running "softwareupdate --install-rosetta" (without quotes) in the Terminal.app.

    Note that you also have to configure Rosetta in the guest Linux VM by following the
    steps from "Mount the Shared Directory and Register Rosetta" section here:
    https://developer.apple.com/documentation/virtualization/running_intel_binaries_in_linux_vms_with_rosetta#3978496
    """,
    valueName: "tag"
  ))
  var rosettaTag: String?

  @Option(help: ArgumentHelp("""
  Additional directory shares with an optional read-only specifier\n(e.g. --dir=\"~/src/build\" or --dir=\"~/src/sources:ro\")
  """, discussion: """
  Requires host to be macOS 13.0 (Ventura) or newer.
  A shared directory is automatically mounted to "/Volumes/My Shared Files" directory on macOS,
  while on Linux you have to do it manually: "mount -t virtiofs com.apple.virtio-fs.automount /mount/point".
  For macOS guests, they must be running macOS 13.0 (Ventura) or newer.

  In case of passing multiple directories it is required to prefix them with names e.g. --dir=\"build:~/src/build\" --dir=\"sources:~/src/sources:ro\"
  These names will be used as directory names under the mounting point inside guests. For the example above it will be
  "/Volumes/My Shared Files/build" and "/Volumes/My Shared Files/sources" respectively.
  """, valueName: "[name:]path[:ro]"))
  var dir: [String] = []

  @Option(help: ArgumentHelp("""
  Use bridged networking instead of the default shared (NAT) networking \n(e.g. --net-bridged=en0 or --net-bridged=\"Wi-Fi\")
  """, discussion: """
  Specify "list" as an interface name (--net-bridged=list) to list the available bridged interfaces.
  """, valueName: "interface name"))
  var netBridged: [String] = []

  @Flag(help: ArgumentHelp("Use software networking instead of the default shared (NAT) networking",
                           discussion: "Learn how to configure Softnet for use with Tart here: https://github.com/cirruslabs/softnet"))
  var netSoftnet: Bool = false

  @Flag(help: ArgumentHelp("Disables audio and entropy devices and switches to only Mac-specific input devices.", discussion: "Useful for running a VM that can be suspended via \"tart suspend\"."))
  var suspendable: Bool = false

  mutating func validate() throws {
    if vnc && vncExperimental {
      throw ValidationError("--vnc and --vnc-experimental are mutually exclusive")
    }

    if netBridged.count > 0 && netSoftnet {
      throw ValidationError("--net-bridged and --net-softnet are mutually exclusive")
    }

    if graphics && noGraphics {
      throw ValidationError("--graphics and --no-graphics are mutually exclusive")
    }

    let localStorage = VMStorageLocal()
    let vmDir = try localStorage.open(name)
    if try vmDir.state() == "suspended" {
      suspendable = true
    }
  }

  @MainActor
  func run() async throws {
    let localStorage = VMStorageLocal()
    let vmDir = try localStorage.open(name)

    let storageLock = try FileLock(lockURL: Config().tartHomeDir)
    if try vmDir.state() == "suspended" {
      try storageLock.lock() // lock before checking
      let needToGenerateNewMac = try localStorage.list().contains {
        // check if there is a running VM with the same MAC but different name
        try $1.running() && $1.macAddress() == vmDir.macAddress() && $1.name != vmDir.name
      }

      if needToGenerateNewMac {
        print("There is already a running VM with the same MAC address!")
        print("Resetting VM to assign a new MAC address...")
        try vmDir.regenerateMACAddress()
      }
    }

    if netSoftnet && isInteractiveSession() {
      try Softnet.configureSUIDBitIfNeeded()
    }

    let additionalDiskAttachments = try additionalDiskAttachments()

    // Error out if the disk is locked by the host (e.g. it was mounted in Finder),
    // see https://github.com/cirruslabs/tart/issues/323 for more details.
    for additionalDiskAttachment in additionalDiskAttachments {
      // Read-only attachments do not seem to acquire the lock
      if additionalDiskAttachment.isReadOnly {
        continue
      }

      if try !FileLock(lockURL: additionalDiskAttachment.url).trylock() {
        throw RuntimeError.DiskAlreadyInUse("disk \(additionalDiskAttachment.url.path) seems to be already in use, "
          + "unmount it first in Finder")
      }
    }

    var serialPorts: [VZSerialPortConfiguration] = []
    if serial {
      let tty_fd = createPTY()
      if (tty_fd < 0) {
        throw RuntimeError.VMConfigurationError("Failed to create PTY")
      }
      let tty_read = FileHandle.init(fileDescriptor: tty_fd)
      let tty_write = FileHandle.init(fileDescriptor: tty_fd)
      serialPorts.append(createSerialPortConfiguration(tty_read, tty_write))
    } else if serialPath != nil {
      let tty_read = FileHandle.init(forReadingAtPath: serialPath!)
      let tty_write = FileHandle.init(forWritingAtPath: serialPath!)
      if (tty_read == nil || tty_write == nil) {
        throw RuntimeError.VMConfigurationError("Failed to open PTY")
      }
      serialPorts.append(createSerialPortConfiguration(tty_read!, tty_write!))
    }

    vm = try VM(
      vmDir: vmDir,
      network: userSpecifiedNetwork(vmDir: vmDir) ?? NetworkShared(),
      additionalDiskAttachments: additionalDiskAttachments,
      directorySharingDevices: directoryShares() + rosettaDirectoryShare(),
      serialPorts: serialPorts,
      suspendable: suspendable
    )

    let vncImpl: VNC? = try {
      if vnc {
        let vmConfig = try VMConfig.init(fromURL: vmDir.configURL)
        return ScreenSharingVNC(vmConfig: vmConfig)
      } else if vncExperimental {
        return FullFledgedVNC(virtualMachine: vm!.virtualMachine)
      } else {
        return nil
      }
    }()

    // Lock the VM
    //
    // More specifically, lock the "config.json", because we can't lock
    // directories with fcntl(2)-based locking and we better not interfere
    // with the VM's disk and NVRAM, because they are opened (and even seem
    // to be locked) directly by the Virtualization.Framework's process.
    //
    // Note that due to "completely stupid semantics"[1] of the fcntl-based
    // file locking, we need to acquire the lock after we read the VM's
    // configuration file, otherwise we will loose the lock.
    //
    // [1]: https://man.openbsd.org/fcntl
    let lock = try PIDLock(lockURL: vmDir.configURL)
    if try !lock.trylock() {
      throw RuntimeError.VMAlreadyRunning("VM \"\(name)\" is already running!")
    }

    // now VM state will return "running" so we can unlock
    try storageLock.unlock()

    let task = Task {
      do {
        var resume = false

        if #available(macOS 14, *) {
          if FileManager.default.fileExists(atPath: vmDir.stateURL.path) {
            print("restoring VM state from a snapshot...")
            try await vm!.virtualMachine.restoreMachineStateFrom(url: vmDir.stateURL)
            try FileManager.default.removeItem(at: vmDir.stateURL)
            resume = true
            print("resuming VM...")
          }
        }
          
        let startOptions = VMStartOptions(
          startUpFromMacOSRecovery: recovery,
          forceDFU: dfu,
          stopOnFatalError: stopOnFatalError,
          stopOnPanic: stopOnPanic,
          stopInIBootStage1: stopInIBootStage1,
          stopInIBootStage2: stopInIBootStage2
        )

        try await vm!.start(vmStartOptions: startOptions, resume: resume)

        if let vncImpl = vncImpl {
          let vncURL = try await vncImpl.waitForURL()

          if noGraphics || ProcessInfo.processInfo.environment["CI"] != nil {
            print("VNC server is running at \(vncURL)")
          } else {
            print("Opening \(vncURL)...")
            NSWorkspace.shared.open(vncURL)
          }
        }

        try await vm!.run()

        if let vncImpl = vncImpl {
          try vncImpl.stop()
        }

        Foundation.exit(0)
      } catch {
        // Capture the error into Sentry
        SentrySDK.capture(error: error)
        SentrySDK.flush(timeout: 2.seconds.timeInterval)

        fputs("\(error)\n", stderr)

        Foundation.exit(1)
      }
    }

    // "tart stop" support
    let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT)
    sigintSrc.setEventHandler {
      task.cancel()
    }
    sigintSrc.activate()

    // "tart suspend" / UI window closing support
    signal(SIGUSR1, SIG_IGN)
    let sigusr1Src = DispatchSource.makeSignalSource(signal: SIGUSR1)
    sigusr1Src.setEventHandler {
      Task {
        do {
          if #available(macOS 14, *) {
            try vm!.configuration.validateSaveRestoreSupport()

            print("pausing VM to take a snapshot...")
            try await vm!.virtualMachine.pause()

            print("creating a snapshot...")
            try await vm!.virtualMachine.saveMachineStateTo(url: vmDir.stateURL)

            print("snapshot created successfully! shutting down the VM...")

            task.cancel()
          } else {
            print(RuntimeError.SuspendFailed("this functionality is only supported on macOS 14 (Sonoma) or newer"))

            Foundation.exit(1)
          }
        } catch (let e) {
          print(RuntimeError.SuspendFailed(e.localizedDescription))

          Foundation.exit(1)
        }
      }
    }
    sigusr1Src.activate()

    let useVNCWithoutGraphics = (vnc || vncExperimental) && !graphics
    if noGraphics || useVNCWithoutGraphics {
      dispatchMain()
    } else {
      runUI(suspendable)
    }
  }

  private func createSerialPortConfiguration(_ tty_read: FileHandle, _ tty_write: FileHandle) -> VZVirtioConsoleDeviceSerialPortConfiguration {
    let serialPortConfiguration = VZVirtioConsoleDeviceSerialPortConfiguration()
    let serialPortAttachment = VZFileHandleSerialPortAttachment(
      fileHandleForReading: tty_read,
      fileHandleForWriting: tty_write)

    serialPortConfiguration.attachment = serialPortAttachment
    return serialPortConfiguration
  }

  func isInteractiveSession() -> Bool {
    isatty(STDOUT_FILENO) == 1
  }

  func userSpecifiedNetwork(vmDir: VMDirectory) throws -> Network? {
    if netSoftnet {
      let config = try VMConfig.init(fromURL: vmDir.configURL)

      return try Softnet(vmMACAddress: config.macAddress.string)
    }

    if netBridged.count > 0 {      
      func findBridgedInterface(_ name: String) throws -> VZBridgedNetworkInterface {
        let interface = VZBridgedNetworkInterface.networkInterfaces.first { interface in
          interface.identifier == name || interface.localizedDisplayName == name
        }
        if (interface == nil) {
          throw ValidationError("no bridge interfaces matched \"\(netBridged)\", "
            + "available interfaces: \(bridgeInterfaces())")
        }
        return interface!
      }

      return NetworkBridged(interfaces: try netBridged.map { try findBridgedInterface($0) })
    }

    return nil
  }

  func bridgeInterfaces() -> [String] {
    VZBridgedNetworkInterface.networkInterfaces.map { interface in
      var bridgeDescription = interface.identifier

      if let localizedDisplayName = interface.localizedDisplayName {
        bridgeDescription += " (or \"\(localizedDisplayName)\")"
      }

      return bridgeDescription
    }
  }

  func additionalDiskAttachments() throws -> [VZDiskImageStorageDeviceAttachment] {
    var result: [VZDiskImageStorageDeviceAttachment] = []
    let readOnlySuffix = ":ro"
    let expandedDiskPaths = disk.map { NSString(string:$0).expandingTildeInPath }

    for rawDisk in expandedDiskPaths {
      if rawDisk.hasSuffix(readOnlySuffix) {
        result.append(try VZDiskImageStorageDeviceAttachment(
          url: URL(fileURLWithPath: String(rawDisk.prefix(rawDisk.count - readOnlySuffix.count))),
          readOnly: true
        ))
      } else {
        result.append(try VZDiskImageStorageDeviceAttachment(
          url: URL(fileURLWithPath: rawDisk),
          readOnly: false
        ))
      }
    }

    return result
  }

  func directoryShares() throws -> [VZDirectorySharingDeviceConfiguration] {
    if dir.isEmpty {
      return []
    }

    guard #available(macOS 13, *) else {
      throw UnsupportedOSError("directory sharing", "is")
    }

    var directoryShares: [DirectoryShare] = []

    var allNamedShares = true
    for rawDir in dir {
      let directoryShare = try DirectoryShare(parseFrom: rawDir)
      if (directoryShare.name == nil) {
        allNamedShares = false
      }
      directoryShares.append(directoryShare)
    }


    let automountTag = VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag
    let sharingDevice = VZVirtioFileSystemDeviceConfiguration(tag: automountTag)
    if allNamedShares {
      var directories: [String : VZSharedDirectory] = Dictionary()
      directoryShares.forEach { directories[$0.name!] = VZSharedDirectory(url: $0.path, readOnly: $0.readOnly) }
      sharingDevice.share = VZMultipleDirectoryShare(directories: directories)
    } else if dir.count > 1 {
      throw ValidationError("invalid --dir syntax: for multiple directory shares each one of them should be named")
    } else if dir.count == 1 {
      let directoryShare = directoryShares.first!
      let singleDirectoryShare = VZSingleDirectoryShare(directory: VZSharedDirectory(url: directoryShare.path, readOnly: directoryShare.readOnly))
      sharingDevice.share = singleDirectoryShare
    }

    return [sharingDevice]
  }

  private func rosettaDirectoryShare() throws -> [VZDirectorySharingDeviceConfiguration] {
    guard let rosettaTag = rosettaTag else {
      return []
    }

    guard #available(macOS 13, *) else {
      throw UnsupportedOSError("Rosetta directory share", "is")
    }

    switch VZLinuxRosettaDirectoryShare.availability {
    case .notInstalled:
      throw UnsupportedOSError("Rosetta directory share", "is", "that have Rosetta installed")
    case .notSupported:
      throw UnsupportedOSError("Rosetta directory share", "is", "running Apple silicon")
    default:
      break
    }

    try VZVirtioFileSystemDeviceConfiguration.validateTag(rosettaTag)
    let device = VZVirtioFileSystemDeviceConfiguration(tag: rosettaTag)
    device.share = try VZLinuxRosettaDirectoryShare()

    return [device]
  }

  private func runUI(_ suspendable: Bool) {
    let nsApp = NSApplication.shared
    nsApp.setActivationPolicy(.regular)
    nsApp.activate(ignoringOtherApps: true)

    nsApp.applicationIconImage = NSImage(data: AppIconData)

    struct MainApp: App {
      static var disappearSignal: Int32 = SIGINT

      @NSApplicationDelegateAdaptor private var appDelegate: MinimalMenuAppDelegate

      var body: some Scene {
        WindowGroup(vm!.name) {
          Group {
            VMView(vm: vm!).onAppear {
              NSWindow.allowsAutomaticWindowTabbing = false
            }.onDisappear {
              let ret = kill(getpid(), MainApp.disappearSignal)
              if ret != 0 {
                // Fallback to the old termination method that doesn't
                // propagate the cancellation to Task's in case graceful
                // termination via kill(2) is not successful
                NSApplication.shared.terminate(self)
              }
            }
          }.frame(
            minWidth: CGFloat(vm!.config.display.width),
            idealWidth: CGFloat(vm!.config.display.width),
            maxWidth: .infinity,
            minHeight: CGFloat(vm!.config.display.height),
            idealHeight: CGFloat(vm!.config.display.height),
            maxHeight: .infinity
          )
        }.commands {
          // Remove some standard menu options
          CommandGroup(replacing: .help, addition: {})
          CommandGroup(replacing: .newItem, addition: {})
          CommandGroup(replacing: .pasteboard, addition: {})
          CommandGroup(replacing: .textEditing, addition: {})
          CommandGroup(replacing: .undoRedo, addition: {})
          CommandGroup(replacing: .windowSize, addition: {})
          // Replace some standard menu options
          CommandGroup(replacing: .appInfo) { AboutTart(config: vm!.config) }
          CommandMenu("Control") {
            Button("Start") {
              Task { try await vm!.virtualMachine.start() }
            }
            Button("Stop") {
              Task { try await vm!.virtualMachine.stop() }
            }
            Button("Request Stop") {
              Task { try vm!.virtualMachine.requestStop() }
            }
            if #available(macOS 14, *) {
              Button("Suspend") {
                kill(getpid(), SIGUSR1)
              }
            }
          }
        }
      }
    }

    MainApp.disappearSignal = suspendable ? SIGUSR1 : SIGINT
    MainApp.main()
  }
}

// The only way to fully remove Edit menu item.
class MinimalMenuAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
  let indexOfEditMenu = 2

  func applicationDidFinishLaunching(_ : Notification) {
    NSApplication.shared.mainMenu?.removeItem(at: indexOfEditMenu)
  }
}

struct AboutTart: View {
  var credits: NSAttributedString

  init(config: VMConfig) {
    let mutableAttrStr = NSMutableAttributedString()
    let style = NSMutableParagraphStyle()
    style.alignment = NSTextAlignment.center
    let attrCenter: [NSAttributedString.Key : Any] = [
      .paragraphStyle: style,
    ]
    mutableAttrStr.append(NSAttributedString(string: "CPU: \(config.cpuCount) cores\n", attributes: attrCenter))
    mutableAttrStr.append(NSAttributedString(string: "Memory: \(config.memorySize / 1024 / 1024) MB\n", attributes: attrCenter))
    mutableAttrStr.append(NSAttributedString(string: "Display: \(config.display.description)\n", attributes: attrCenter))
    mutableAttrStr.append(NSAttributedString(string: "https://github.com/cirruslabs/tart", attributes: [
      .paragraphStyle: style,
      .link : "https://github.com/cirruslabs/tart"
    ]))
    credits = mutableAttrStr
  }

  var body: some View {
    Button("About Tart") {
      NSApplication.shared.orderFrontStandardAboutPanel(options: [
        NSApplication.AboutPanelOptionKey.applicationIcon: NSApplication.shared.applicationIconImage as Any,
        NSApplication.AboutPanelOptionKey.applicationName: "Tart",
        NSApplication.AboutPanelOptionKey.applicationVersion: CI.version,
        NSApplication.AboutPanelOptionKey.credits: credits,
      ])
    }
  }
}

struct VMView: NSViewRepresentable {
  typealias NSViewType = VZVirtualMachineView

  @ObservedObject var vm: VM

  func makeNSView(context: Context) -> NSViewType {
    let machineView = VZVirtualMachineView()

    // Do not capture system keys so that shortcuts like
    // Shift-Command-4 + Space (capture a screenshot of window)
    // work on the host instead of the guest
    machineView.capturesSystemKeys = false

    // Enable automatic display reconfiguration
    // for guests that support it
    if #available(macOS 14.0, *) {
      machineView.automaticallyReconfiguresDisplay = true
    }

    return machineView
  }

  func updateNSView(_ nsView: NSViewType, context: Context) {
    nsView.virtualMachine = vm.virtualMachine
  }
}

struct DirectoryShare {
  let name: String?
  let path: URL
  let readOnly: Bool

  init(parseFrom: String) throws {
    let splits = parseFrom.split(maxSplits: 2) { $0 == ":" }

    if splits.count == 3 {
      if splits[2] == "ro" {
        readOnly = true
      } else {
        throw ValidationError("invalid --dir syntax: optional read-only specifier can only be \"ro\"")
      }
      name = String(splits[0])
      path = String(splits[1]).toFilePathURL()
    } else if splits.count == 2 {
      if splits[1] == "ro" {
        name = nil
        path = String(splits[0]).toFilePathURL()
        readOnly = true
      } else {
        name = String(splits[0])
        path = String(splits[1]).toFilePathURL()
        readOnly = false
      }
    } else {
      name = nil
      path = String(splits[0]).toFilePathURL()
      readOnly = false
    }
  }
}

extension String {
  func toFilePathURL() -> URL {
    URL(fileURLWithPath: NSString(string: self).expandingTildeInPath)
  }
}
