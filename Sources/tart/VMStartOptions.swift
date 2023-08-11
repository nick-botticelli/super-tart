struct VMStartOptions {
  var startUpFromMacOSRecovery: Bool
  var forceDFU: Bool
  var stopOnFatalError: Bool
  var stopOnPanic: Bool
  var stopInIBootStage1: Bool
  var stopInIBootStage2: Bool
}
