import Foundation
import Virtualization
import AsyncAlgorithms
import Dynamic

struct UnsupportedRestoreImageError: Error {
}

struct NoMainScreenFoundError: Error {
}

struct DownloadFailed: Error {
}

struct UnsupportedOSError: Error, CustomStringConvertible {
  let description: String

  init(_ what: String, _ plural: String, _ requires: String = "running macOS 13.0 (Ventura) or newer") {
    description = "error: \(what) \(plural) only supported on hosts \(requires)"
  }
}

struct UnsupportedArchitectureError: Error {
}

class VM: NSObject, VZVirtualMachineDelegate, ObservableObject {
  // Virtualization.Framework's virtual machine
  @Published var virtualMachine: VZVirtualMachine

  // Virtualization.Framework's virtual machine configuration
  var configuration: VZVirtualMachineConfiguration

  // Semaphore used to communicate with the VZVirtualMachineDelegate
  var sema = DispatchSemaphore(value: 0)

  // VM's config
  var name: String

  // VM's config
  var config: VMConfig

  var network: Network

  init(vmDir: VMDirectory,
       network: Network = NetworkShared(),
       additionalDiskAttachments: [VZDiskImageStorageDeviceAttachment] = [],
       directorySharingDevices: [VZDirectorySharingDeviceConfiguration] = [],
       serialPorts: [VZSerialPortConfiguration] = [],
       suspendable: Bool = false
  ) throws {
    name = vmDir.name
    config = try VMConfig.init(fromURL: vmDir.configURL)

    if config.arch != CurrentArchitecture() {
      throw UnsupportedArchitectureError()
    }

    // Initialize the virtual machine and its configuration
    self.network = network
    configuration = try Self.craftConfiguration(diskURL: vmDir.diskURL,
                                                    nvramURL: vmDir.nvramURL, romURL: vmDir.romURL, vmConfig: config,
                                                    network: network, additionalDiskAttachments: additionalDiskAttachments,
                                                    directorySharingDevices: directorySharingDevices,
                                                    serialPorts: serialPorts,
                                                    suspendable: suspendable
    )
    virtualMachine = VZVirtualMachine(configuration: configuration)

    super.init()
    virtualMachine.delegate = self
  }

  static func retrieveIPSW(remoteURL: URL) async throws -> URL {
    // Check if we already have this IPSW in cache
    let (channel, response) = try await Fetcher.fetch(URLRequest(url: remoteURL), viaFile: true)

    if let hash = response.value(forHTTPHeaderField: "x-amz-meta-digest-sha256") {
      let ipswLocation = try IPSWCache().locationFor(fileName: "sha256:\(hash).ipsw")

      if FileManager.default.fileExists(atPath: ipswLocation.path) {
        defaultLogger.appendNewLine("Using cached *.ipsw file...")
        try ipswLocation.updateAccessDate()

        return ipswLocation
      }
    }

    // Download the IPSW
    defaultLogger.appendNewLine("Fetching \(remoteURL.lastPathComponent)...")

    let progress = Progress(totalUnitCount: response.expectedContentLength)
    ProgressObserver(progress).log(defaultLogger)

    let temporaryLocation = try Config().tartTmpDir.appendingPathComponent(UUID().uuidString + ".ipsw")
    FileManager.default.createFile(atPath: temporaryLocation.path, contents: nil)
    let lock = try FileLock(lockURL: temporaryLocation)
    try lock.lock()

    let fileHandle = try FileHandle(forWritingTo: temporaryLocation)
    let digest = Digest()

    for try await chunk in channel {
      let chunkAsData = Data(chunk)
      fileHandle.write(chunkAsData)
      digest.update(chunkAsData)
      progress.completedUnitCount += Int64(chunk.count)
    }

    try fileHandle.close()

    let finalLocation = try IPSWCache().locationFor(fileName: digest.finalize() + ".ipsw")

    return try FileManager.default.replaceItemAt(finalLocation, withItemAt: temporaryLocation)!
  }

  static func latestIPSWURL() async throws -> URL {
    defaultLogger.appendNewLine("Looking up the latest supported IPSW...")

    let image = try await withCheckedThrowingContinuation { continuation in
      VZMacOSRestoreImage.fetchLatestSupported() { result in
        continuation.resume(with: result)
      }
    }

    return image.url
  }

  var inFinalState: Bool {
    get {
      virtualMachine.state == VZVirtualMachine.State.stopped ||
        virtualMachine.state == VZVirtualMachine.State.paused ||
        virtualMachine.state == VZVirtualMachine.State.error

    }
  }

  init(
    vmDir: VMDirectory,
    ipswURL: URL,
    diskSizeGB: UInt16,
    romURL: URL,
    network: Network = NetworkShared(),
    additionalDiskAttachments: [VZDiskImageStorageDeviceAttachment] = [],
    directorySharingDevices: [VZDirectorySharingDeviceConfiguration] = [],
    serialPorts: [VZSerialPortConfiguration] = []
  ) async throws {
    var ipswURL = ipswURL

    if !ipswURL.isFileURL {
      ipswURL = try await VM.retrieveIPSW(remoteURL: ipswURL)
    }

    // We create a temporary TART_HOME directory in tests, which has its "cache" folder symlinked
    // to the users Tart cache directory (~/.tart/cache). However, the Virtualization.Framework
    // cannot deal with paths that contain symlinks, so expand them here first.
    ipswURL.resolveSymlinksInPath()

    // Load the restore image and try to get the requirements
    // that match both the image and our platform
    let image = try await withCheckedThrowingContinuation { continuation in
      VZMacOSRestoreImage.load(from: ipswURL) { result in
        continuation.resume(with: result)
      }
    }

    guard let requirements = image.mostFeaturefulSupportedConfiguration else {
      throw UnsupportedRestoreImageError()
    }

    // Create NVRAM
    _ = try VZMacAuxiliaryStorage(creatingStorageAt: vmDir.nvramURL, hardwareModel: requirements.hardwareModel)

    // Create disk
    try vmDir.resizeDisk(diskSizeGB)

    name = vmDir.name
    // Create config
    config = VMConfig(
      platform: Darwin(ecid: VZMacMachineIdentifier(), hardwareModel: requirements.hardwareModel),
      cpuCountMin: requirements.minimumSupportedCPUCount,
      memorySizeMin: requirements.minimumSupportedMemorySize
    )
    // allocate at least 4 CPUs because otherwise VMs are frequently freezing
    try config.setCPU(cpuCount: max(4, requirements.minimumSupportedCPUCount))
    try config.save(toURL: vmDir.configURL)
      
    // Copy ROM
    try FileManager.default.copyItem(atPath: romURL.path, toPath: vmDir.romURL.path)

    // Initialize the virtual machine and its configuration
    self.network = network
    configuration = try Self.craftConfiguration(diskURL: vmDir.diskURL, nvramURL: vmDir.nvramURL,
                                                    romURL: vmDir.romURL, vmConfig: config, network: network,
                                                    additionalDiskAttachments: additionalDiskAttachments,
                                                    directorySharingDevices: directorySharingDevices,
                                                    serialPorts: serialPorts
    )
    virtualMachine = VZVirtualMachine(configuration: configuration)

    super.init()
    virtualMachine.delegate = self

    // Run automated installation
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      DispatchQueue.main.async { [ipswURL] in
        let installer = VZMacOSInstaller(virtualMachine: self.virtualMachine, restoringFromImageAt: ipswURL)

        defaultLogger.appendNewLine("Installing OS...")
        ProgressObserver(installer.progress).log(defaultLogger)

        installer.install { result in
          continuation.resume(with: result)
        }
      }
    }
  }

  @available(macOS 13, *)
  static func linux(vmDir: VMDirectory, diskSizeGB: UInt16) async throws -> VM {
    // Create NVRAM
    _ = try VZEFIVariableStore(creatingVariableStoreAt: vmDir.nvramURL)

    // Create disk
    try vmDir.resizeDisk(diskSizeGB)

    // Create config
    let config = VMConfig(platform: Linux(), cpuCountMin: 4, memorySizeMin: 4096 * 1024 * 1024)
    try config.save(toURL: vmDir.configURL)

    return try VM(vmDir: vmDir)
  }

  func start(vmStartOptions: VMStartOptions, resume shouldResume: Bool) async throws {
    try network.run(sema)

    if shouldResume {
      try await resume()
    } else {
      try await start(vmStartOptions)
    }
  }

  func run() async throws {
    await withTaskCancellationHandler(operation: {
      // Wait for the VM to finish running
      // or for the exit condition
      sema.wait()
    }, onCancel: {
      sema.signal()
    })

    if Task.isCancelled {
      try await stop()
    }

    try await network.stop()
  }

  @MainActor
  private func start(_ vmStartOptions: VMStartOptions) async throws {
    if #available(macOS 13, *) {
      // new API introduced in Ventura
      let startOptions = VZMacOSVirtualMachineStartOptions()
      startOptions.startUpFromMacOSRecovery = vmStartOptions.startUpFromMacOSRecovery
      Dynamic(startOptions)._setForceDFU(vmStartOptions.forceDFU)
      Dynamic(startOptions)._setPanicAction(vmStartOptions.stopOnPanic)
      Dynamic(startOptions)._setStopInIBootStage1(vmStartOptions.stopInIBootStage1)
      Dynamic(startOptions)._setStopInIBootStage2(vmStartOptions.stopInIBootStage2)
        
      if #available(macOS 14, *) {
        Dynamic(startOptions)._setFatalErrorAction(vmStartOptions.stopOnFatalError)
      }

      try await virtualMachine.start(options: startOptions)
    } else {
      // use method that also available on Monterey
      try await virtualMachine.start(vmStartOptions.startUpFromMacOSRecovery)
    }
  }

  @MainActor
  private func resume() async throws {
    try await virtualMachine.resume()
  }

  @MainActor
  private func stop() async throws {
    try await self.virtualMachine.stop()
  }

  static func craftConfiguration(
    diskURL: URL,
    nvramURL: URL,
    romURL: URL,
    vmConfig: VMConfig,
    network: Network = NetworkShared(),
    additionalDiskAttachments: [VZDiskImageStorageDeviceAttachment],
    directorySharingDevices: [VZDirectorySharingDeviceConfiguration],
    serialPorts: [VZSerialPortConfiguration],
    suspendable: Bool = false
  ) throws -> VZVirtualMachineConfiguration {
    let configuration = VZVirtualMachineConfiguration()

    // Boot loader
    let bootloader = try vmConfig.platform.bootLoader(nvramURL: nvramURL)
    Dynamic(bootloader)._setROMURL(romURL)
    configuration.bootLoader = bootloader

    // CPU and memory
    configuration.cpuCount = vmConfig.cpuCount
    configuration.memorySize = vmConfig.memorySize

    // Platform
    configuration.platform = try vmConfig.platform.platform(nvramURL: nvramURL)

    // Display
    configuration.graphicsDevices = [vmConfig.platform.graphicsDevice(vmConfig: vmConfig)]

    // Audio
    if !suspendable {
      let soundDeviceConfiguration = VZVirtioSoundDeviceConfiguration()
      let inputAudioStreamConfiguration = VZVirtioSoundDeviceInputStreamConfiguration()
      inputAudioStreamConfiguration.source = VZHostAudioInputStreamSource()
      let outputAudioStreamConfiguration = VZVirtioSoundDeviceOutputStreamConfiguration()
      outputAudioStreamConfiguration.sink = VZHostAudioOutputStreamSink()
      soundDeviceConfiguration.streams = [inputAudioStreamConfiguration, outputAudioStreamConfiguration]
      configuration.audioDevices = [soundDeviceConfiguration]
    }

    // Keyboard and mouse
    if suspendable, let platformSuspendable = vmConfig.platform.self as? PlatformSuspendable {
      configuration.keyboards = platformSuspendable.keyboardsSuspendable()
      configuration.pointingDevices = platformSuspendable.pointingDevicesSuspendable()
    } else {
      configuration.keyboards = vmConfig.platform.keyboards()
      configuration.pointingDevices = vmConfig.platform.pointingDevices()
    }

    // Networking
    configuration.networkDevices = network.attachments().map {
      let vio = VZVirtioNetworkDeviceConfiguration()
      vio.attachment = $0
      vio.macAddress = vmConfig.macAddress
      return vio  
    }

    // Storage
    var attachments = [try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)]
    attachments.append(contentsOf: additionalDiskAttachments)
    configuration.storageDevices = attachments.map { VZVirtioBlockDeviceConfiguration(attachment: $0) }

    // Entropy
    if !suspendable {
      configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    }

    // Directory sharing devices
    configuration.directorySharingDevices = directorySharingDevices
      
    // Debug port
    let debugStub = Dynamic._VZGDBDebugStubConfiguration(port: vmConfig.debugPort)
    Dynamic(configuration)._setDebugStub(debugStub)

    // Serial console; configure only if no prior serial ports are configured
    if serialPorts.isEmpty {
      // Configure internal Mac serial I/O
      let serialPort: VZSerialPortConfiguration = Dynamic._VZPL011SerialPortConfiguration().asObject as! VZSerialPortConfiguration
      serialPort.attachment = VZFileHandleSerialPortAttachment(
        fileHandleForReading: FileHandle.standardInput,
        fileHandleForWriting: FileHandle.standardOutput
      )
      configuration.serialPorts = [serialPort]
    } else {
      // Previously configured serial ports
      configuration.serialPorts = serialPorts
    }

    // Version console device
    //
    // A dummy console device useful for implementing
    // host feature checks in the guest agent software.
    if #available(macOS 13, *) {
      let consolePort = VZVirtioConsolePortConfiguration()
      consolePort.name = "tart-version-\(CI.version)"

      let consoleDevice = VZVirtioConsoleDeviceConfiguration()
      consoleDevice.ports[0] = consolePort

      configuration.consoleDevices.append(consoleDevice)
    }

    // Panic device (needed on macOS 14+ when setPanicAction is enabled)
    if #available(macOS 14, *) {
      let panicDevice = Dynamic._VZPvPanicDeviceConfiguration()
      Dynamic(configuration)._setPanicDevice(panicDevice)
    }

    try configuration.validate()

    return configuration
  }

  func guestDidStop(_ virtualMachine: VZVirtualMachine) {
    print("guest has stopped the virtual machine")
    sema.signal()
  }

  func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
    print("guest has stopped the virtual machine due to error: \(error)")
    sema.signal()
  }

  func virtualMachine(_ virtualMachine: VZVirtualMachine, networkDevice: VZNetworkDevice, attachmentWasDisconnectedWithError error: Error) {
    print("virtual machine's network attachment \(networkDevice) has been disconnected with error: \(error)")
    sema.signal()
  }
}
