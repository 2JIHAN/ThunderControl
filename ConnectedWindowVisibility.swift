/// Main-window presentation only. Never includes the invisible source ownership window.
struct ConnectedWindowVisibility {
  enum Action:Equatable {case showMainWindow,hideMainWindow}
  private(set) var isConnected:Bool?
  private(set) var manuallyOpened=false
  var mayRestoreMainWindow:Bool {isConnected != true || manuallyOpened}
  mutating func setConnected(_ connected:Bool)->Action? {
    guard connected != isConnected else{return nil}
    isConnected=connected;manuallyOpened=false
    return connected ? .hideMainWindow:.showMainWindow
  }
  mutating func userOpenedWindow(connected:Bool) {
    isConnected=connected;manuallyOpened=connected
  }
}
func runConnectedWindowVisibilityTests()->Int {
  var checks=0,failures=0
  func check(_ ok:Bool){checks+=1;if !ok{failures+=1}}
  for _ in ["sender","receiver"] {
    var state=ConnectedWindowVisibility()
    check(state.setConnected(false) == .showMainWindow)
    check(state.mayRestoreMainWindow)
    check(state.setConnected(false)==nil)
    check(state.setConnected(true) == .hideMainWindow)
    check(!state.mayRestoreMainWindow)
    check(state.setConnected(true)==nil)
    state.userOpenedWindow(connected:true)
    check(state.mayRestoreMainWindow)
    check(state.setConnected(true)==nil)
    check(state.manuallyOpened)
    check(state.setConnected(false) == .showMainWindow)
    check(!state.manuallyOpened && state.mayRestoreMainWindow)
    check(state.setConnected(true) == .hideMainWindow)
    check(!state.manuallyOpened && !state.mayRestoreMainWindow)
  }
  print("Connected main-window policy: \(checks) checks, \(failures) failures; both roles, manual reopen and reconnect")
  return failures
}
