import CoreGraphics
import Foundation

extension EdgeHandoff {
  mutating func reconfigureLocal(edge newEdge:Edge,arrangement newLayout:ScreenArrangement)->Bool {
    guard phase == .local,newLayout.isValid,newLayout.remoteOnRight == (newEdge == .right) else{return false}
    self=EdgeHandoff(edge:newEdge)
    arrangement=newLayout
    return true
  }
}
func runConnectedLayoutTests()->Int {
  var failed=0
  func check(_ value:Bool){if !value {failed+=1}}
  let right=ScreenArrangement(sourceSize:CGSize(width:1920,height:1080),remoteSize:CGSize(width:2560,height:1440),remoteOnRight:true,offsetY:200)
  let left=ScreenArrangement(sourceSize:right.sourceSize,remoteSize:right.remoteSize,remoteOnRight:false,offsetY:-300)
  var state=EdgeHandoff();state.token=UUID().uuidString;state.latched=false;state.dwell=4
  check(state.reconfigureLocal(edge:.right,arrangement:right));check(state.phase == .local && state.token==nil && state.latched && state.dwell==nil)
  check(state.reconfigureLocal(edge:.left,arrangement:left));check(state.edge == .left && state.arrangement==left)
  check(state.arrangement?.remoteY(sourceY:100)==400)
  for phase:EdgeHandoff.Phase in [.pending,.committed,.remote,.targetReady,.targetActive,.returning] {
    state.phase=phase;let token=UUID().uuidString;state.token=token
    check(!state.reconfigureLocal(edge:.right,arrangement:right));check(state.phase==phase && state.token==token && state.arrangement==left)
  }
  state.phase = .local
  check(!state.reconfigureLocal(edge:.right,arrangement:left))
  var invalid=right;invalid.offsetY=5000;check(!state.reconfigureLocal(edge:.right,arrangement:invalid))
  invalid.offsetY = .nan;check(!state.reconfigureLocal(edge:.right,arrangement:invalid))
  print("ConnectedLayout memory-only atomic local updates and stale-token/active-state rejection failures=\(failed)")
  return failed
}
