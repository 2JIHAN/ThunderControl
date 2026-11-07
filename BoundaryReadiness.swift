import Foundation

enum BoundaryBlockedReason:String {
  case disconnected = "Input sharing waits for an authenticated connection."
  case safety = "Input sharing paused by session, topology or safety state."
  case senderInputDisabled = "Sender input sharing is off. Choose Resume Input Sharing."
  case receiverInputDisabled = "Receiver input sharing is off. Choose Resume Input Sharing on this Mac."
  case receiverUnavailable = "Receiver input is unavailable. Check input sharing on the Receiver Mac."
  case inputHeld = "Input sharing waits for held keys, buttons or gestures to finish."
  case handoffInProgress = "Input handoff is already in progress."
  case geometry = "Input sharing waits for authenticated display geometry."
  var localized:String {TCText(rawValue)}
}
