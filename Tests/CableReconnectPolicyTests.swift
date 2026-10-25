import Foundation
import CryptoKit
func runCableReconnectPolicyTests()->Int {
  var failures=0
  func check(_ b:Bool){if !b {failures+=1}}
  for reason in ["Peer closed the TCP connection (EOF)","Receive timed out waiting for peer frame","Receive failed: errno=54","Send failed: errno=32"] {check(isTransientTransportFailure(Failure(reason)))}
  for reason in ["Invalid frame length","Invalid or out-of-order pairing message","Pairing cancelled","Wrong key","Emergency hotkey stop"] {check(!isTransientTransportFailure(Failure(reason)))}
  check(!isTransientTransportFailure(PINPairingError.authenticationFailed));check(!isTransientTransportFailure(CryptoKitError.authenticationFailure))
  check(automaticConnectionMayStart(configured:true,paused:false,suspended:false,permissions:true,sessionSafe:true,recovery:false,hasSession:false))
  check(!automaticConnectionMayStart(configured:true,paused:false,suspended:true,permissions:true,sessionSafe:true,recovery:false,hasSession:false))
  check(shouldSuspendAutomaticReconnect(stage:"Authenticated stream",error:CryptoKitError.authenticationFailure,terminalReason:nil))
  check(shouldSuspendAutomaticReconnect(stage:"Authenticated stream",error:Failure("Malformed authenticated packet"),terminalReason:nil))
  check(!shouldSuspendAutomaticReconnect(stage:"Authenticated stream",error:Failure("Peer closed the TCP connection (EOF)"),terminalReason:nil))
  check(!shouldSuspendAutomaticReconnect(stage:"Trusted pairing",error:PINPairingError.authenticationFailed,terminalReason:"Pairing transport interrupted"))
  check(!shouldSuspendAutomaticReconnect(stage:"Authenticated stream",error:Failure("Inbound queue overload"),terminalReason:nil))
  check(shouldSuspendAutomaticReconnect(stage:"Trusted pairing",error:Failure("Inbound queue overload"),terminalReason:nil))
  check(shouldSuspendAutomaticReconnect(stage:"Authenticated stream",error:Failure("Inbound queue overload: malformed peer payload"),terminalReason:nil))
  check(!automaticConnectionMayStart(configured:true,paused:true,suspended:false,permissions:true,sessionSafe:true,recovery:false,hasSession:false))
  check(!automaticConnectionMayStart(configured:true,paused:false,suspended:false,permissions:true,sessionSafe:true,recovery:true,hasSession:false))
  check(Relay.verifyDevelopmentReconnectTimeoutForTests())
  print("Cable reconnect policy: transport retry versus authentication/emergency suspension failures=\(failures)")
  return failures
}
