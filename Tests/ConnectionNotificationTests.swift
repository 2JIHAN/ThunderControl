import Foundation

/// Pure state tests: no native center, permission queries, network, or input events.
func runConnectionNotificationTests() -> Int {
    var failures = 0
    func check(_ value: Bool, _ label: String) {
        if !value { failures += 1; print("FAIL connection notifications: \(label)") }
    }
    var tracker = ConnectionNotificationTracker()
    check(tracker.disconnected() == nil, "preauthentication failure and listener retry are silent")
    let first = tracker.connected(peerName: "수신 Mac", localIsSender: true)
    check(first?.title == TCText("Connection Established") && first?.body == "\(TCText("Receiving Mac")): 수신 Mac", "sender connection")
    check(tracker.connected(peerName: "changed metadata", localIsSender: true) == nil, "duplicate connect")
    let lost = tracker.disconnected()
    check(lost?.title == TCText("Disconnected") && lost?.body == "\(TCText("Receiving Mac")): 수신 Mac", "remember authenticated peer")
    check(tracker.disconnected() == nil, "duplicate disconnect")
    check(tracker.connected(peerName: "송신 Mac", localIsSender: false)?.body == "\(TCText("Sending Mac")): 송신 Mac", "receiver connection")
    check(tracker.disconnected()?.body == "\(TCText("Sending Mac")): 송신 Mac", "receiver disconnect")
    check(tracker.connected(peerName: "again", localIsSender: false) != nil, "reconnect is new event")
    check(ConnectionNotificationTracker.displayName(" \nMac\u{0}\u{202E}\t ") == "Mac", "remove unsafe scalars")
    check(ConnectionNotificationTracker.displayName("\u{0}\u{2028}\u{2029}") == TCText("Bridge peer"), "empty fallback")
    check(ConnectionNotificationTracker.displayName("José의 Mac") == "José의 Mac", "preserve unicode name")
    for text in [String(repeating: "가", count: 100), String(repeating: "a", count: 200), String(repeating: "🧑🏽‍💻", count: 60)] {
        check(ConnectionNotificationTracker.displayName(text).utf8.count <= 128, "utf8 bound")
    }
    for flag in ["--self-test", "--pairing-integration-test", "--ui-smoke-test", "--ui-ownership-test"] {
        check(ConnectionNotificationTracker.disablesNativeWork(arguments: ["app", flag]), "CLI guard")
    }
    check(!ConnectionNotificationTracker.disablesNativeWork(arguments: ["app"]), "normal launch")
    return failures
}


@MainActor func runSingleConnectionNotificationTests()->Int {
 var tx:[ConnectionNotificationTracker.Event]=[],rx:[ConnectionNotificationTracker.Event]=[],requests=0
 let sender=ConnectionNotifications(deliver:{tx.append($0)},requestAuthorization:{requests+=1})
 let receiver=ConnectionNotifications(deliver:{rx.append($0)})
 sender.requestAuthorizationIfNeeded();sender.requestAuthorizationIfNeeded()
 guard requests==1 else{return 1};sender.requestAuthorizationIfNeeded(forceRetry:true)
 sender.connected(peerName:"수신 Mac",localIsSender:true);receiver.connected(peerName:"송신 Mac",localIsSender:false)
 sender.connected(peerName:"중복",localIsSender:true);receiver.connected(peerName:"중복",localIsSender:false)
 guard requests==2,tx.count==1,rx.count==1,tx[0].body=="\(TCText("Receiving Mac")): 수신 Mac",rx[0].body=="\(TCText("Sending Mac")): 송신 Mac" else{return 1}
 sender.disconnected();receiver.disconnected();sender.disconnected()
 guard tx.count==2,rx.count==2,tx[1].title==TCText("Disconnected"),rx[1].title==TCText("Disconnected") else{return 1}
 sender.connected(peerName:"수신 Mac",localIsSender:true);receiver.connected(peerName:"송신 Mac",localIsSender:false)
 print("Single-peer both-side connection/disconnection/reconnect alerts: native-free PASS")
 return tx.count==3 && rx.count==3 ? 0:1
}
