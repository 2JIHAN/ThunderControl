import AppKit
import Foundation
final class PairingAttemptLimiter {
  static let shared=PairingAttemptLimiter()
  private let lock=NSLock()
  private var attempts:[Double]=[]
  func consume(now:Double=ProcessInfo.processInfo.systemUptime)->Bool {
    lock.lock();defer{lock.unlock()}
    attempts=attempts.filter{now-$0<60}
    guard attempts.count<5 else{return false}
    attempts.append(now);return true
  }
}
private final class PINDecision {
  private let lock=NSLock()
  private var finished=false
  private var value:String?
  func finish(_ pin:String?){lock.lock();defer{lock.unlock()};if !finished {finished=true;value=pin}}
  func result()->(Bool,String?){lock.lock();defer{lock.unlock()};return(finished,value)}
}
@MainActor extension App {
  func installPINApproval() {
    relay.approvePIN = { [weak self] request,cancelled in
      let decision=PINDecision()
      let alertToken=UUID()
      DispatchQueue.main.async {
        guard let self,!cancelled(),self.relay.sessionAllowed else{decision.finish(nil);return}
        guard self.pairingAlert==nil else{decision.finish(nil);return}
        let alert=NSAlert();alert.messageText=TCText("Approve Thunderbolt Connection Request")
        alert.informativeText=TCText("Request: ")+BridgeDiscoveryValidation.displayName(request.senderName)+TCText("\nEnter the 4-digit code shown on the Sender Mac. The name is displayed before authentication, so approve only connections you requested.")
        alert.addButton(withTitle:TCText("Verify Code and Approve"));alert.addButton(withTitle:TCText("Decline"))
        let field=NSTextField(frame:NSRect(x:0,y:0,width:180,height:28));field.placeholderString=TCText("4 digits")
        alert.accessoryView=field;self.pairingAlert=alert;self.pairingAlertToken=alertToken
        self.window.makeKeyAndOrderFront(nil);NSApp.requestUserAttention(.informationalRequest)
        alert.beginSheetModal(for:self.window) { [weak self] reply in
          defer {field.stringValue="";if self?.pairingAlert === alert {self?.pairingAlert=nil;self?.pairingAlertToken=nil}}
          let pin=field.stringValue
          guard reply == .alertFirstButtonReturn,pin.utf8.count==4,pin.utf8.allSatisfy({(48...57).contains($0)}),!cancelled() else{decision.finish(nil);return}
          decision.finish(pin)
        }
      }
      let deadline=ProcessInfo.processInfo.systemUptime+90
      while true {
        let (done,pin)=decision.result()
        if done {guard let pin else{throw Failure("PIN approval cancelled or invalid")};return pin}
        if cancelled() || ProcessInfo.processInfo.systemUptime>=deadline {
          decision.finish(nil)
          DispatchQueue.main.async { [weak self] in if let self,self.pairingAlertToken==alertToken,let alert=self.pairingAlert {self.window.endSheet(alert.window,returnCode:.abort);self.pairingAlert=nil;self.pairingAlertToken=nil} }
          throw Failure("PIN approval cancelled or timed out")
        }
        Thread.sleep(forTimeInterval:0.05)
      }
    }
  }
}
