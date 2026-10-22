import Foundation
import CoreGraphics
import CryptoKit

// MARK: - Pure Relay integration tests for the receiver desktop map protocol.
//
// These tests exercise sender-side adoption behavior of ReceiverDesktop maps
// delivered via `available` Wire packets, strict role/revision rules in the
// PeerValidator, callback fan-out, and the authenticated transport identity
// (socket, context, key, generation UUID) remaining untouched when a receiver
// publishes a new map or when the sender rearranges its source attachment.
//
// Nothing posts real input, performs real screen capture, opens real sockets,
// or writes keychain state. Every store is an isolated UserDefaults suite that
// is torn down at scope exit.
@discardableResult func runReceiverDesktopRelayTests()->Int {
    var failures=0,checks=0
    func check(_ condition:Bool,_ note:String="unlabeled"){checks+=1;if !condition{failures+=1;fputs("ReceiverDesktopRelay check failed: \(note)\n",stderr)}}

    check(Relay.verifyReceiverSingleMapReadForTests(),"actual receiver single-map input path")

    // Simple pair identity utility.
    let localID=UUID().uuidString,peerID=UUID().uuidString
    guard let pair=LayoutDevicePair(localID:localID,peerID:peerID) else{failures+=1;return failures}

    // ------------------------------------------------------------------
    // 1) PeerValidator: receiver desktop map is only valid on an "available"
    //    packet from the authenticated receiver, bounded in size, and never
    //    appears on event/dock/appGesture/begin/barrier packets.
    // ------------------------------------------------------------------
    let session=UUID().uuidString
    func validatesAvailable(role senderPeer:Bool,map:Data?)->Bool {
        var v=PeerValidator(senderPeer:senderPeer,session:session,concurrentDisplaySupported:true,multiDisplayDesktopSupported:true)
        var w=Wire(kind:"available",session:session,sequence:1,width:0,screenWidth:1920,screenHeight:1080)
        w.receiverDesktopMap=map
        do {try v.accept(w);return v.next==2}catch{return false}
    }
    check(validatesAvailable(role:false,map:Data("{}".utf8)),"receiver map accepted on available")
    check(!validatesAvailable(role:true,map:Data("{}".utf8)),"sender role never carries map")
    check(validatesAvailable(role:false,map:nil),"nil map still valid")
    check(!validatesAvailable(role:false,map:Data(repeating:0,count:9000)),"oversize map rejected")
    check(!validatesAvailable(role:false,map:Data()),"empty map rejected")
    do {
        var v=PeerValidator(senderPeer:false,session:session,concurrentDisplaySupported:true,multiDisplayDesktopSupported:true)
        var w=Wire(kind:"ping",session:session,sequence:1);w.receiverDesktopMap=Data("x".utf8)
        try v.accept(w);check(false,"map on ping rejected")
    } catch {check(true,"map on ping rejected")}

    // ------------------------------------------------------------------
    // 2) Sender-side map adoption via receiveControl("available") preserves
    //    socket, context, key, and generation. Newer revisions replace older,
    //    older/equal revisions are dropped. UI callback fires on real change.
    // ------------------------------------------------------------------
    let suite="ThunderControl.tests.receiver-desktop."+UUID().uuidString
    let defaults=UserDefaults(suiteName:suite)!
    defer{defaults.removePersistentDomain(forName:suite)}
    let store=SavedDesktopPlacementStore(defaults:defaults)

    var fds:[Int32]=[0,0]
    guard socketpair(AF_UNIX,SOCK_STREAM,0,&fds)==0 else{failures+=1;return failures}
    defer{close(fds[1])}
    let socket=OwnedSocket(fds[0]);let context=SessionContext(OwnedSocket(dup(fds[0])))
    defer{context.cancel(reason:"ReceiverDesktopRelayTests fixture end")}

    let relay=Relay(desktopPlacementStore:store)
    relay.senderForTests=true
    relay.contextForTests=context
    relay.connectionForTests=socket
    relay.keyForTests=SymmetricKey(size:.bits256)
    // Pretend an authenticated channel is wired up.
    relay.concurrentDisplayCompatibleForTests=true
    relay.multiDisplayDesktopCompatibleForTests=true
    relay.layoutDevicePairForTests=pair
    relay.pendingInitialSourceOriginRestoreForTests=true
    relay.topologyForTests=DisplayTopologySnapshot(mainID:1,activeIDs:[1],bounds:CGRect(x:0,y:0,width:1200,height:800))

    let keyFingerprint=relay.keyForTests!.withUnsafeBytes{Data($0)}
    let originalGeneration=relay.generation
    var callbackCount=0
    relay.onReceiverDesktopChanged={callbackCount+=1}

    func mapPayload(_ desktop:ReceiverDesktop) throws -> Data {
        try JSONEncoder().encode(desktop)
    }

    let mainReceiverDisplay=ReceiverDisplay(id:11,bounds:CGRect(x:0,y:0,width:1920,height:1080),stableIdentity:UUID().uuidString)
    let firstMap=ReceiverDesktop(revision:5,mainID:11,displays:[mainReceiverDisplay])
    do {
        relay.adoptReceiverDesktopPayloadForTests(try mapPayload(firstMap))
    } catch {failures+=1}
    check(relay.receiverDesktop==firstMap,"first map adopted")
    check(relay.sourceOrigin != nil,"first auth map seeds source origin")
    if let origin=relay.sourceOrigin {
        check(!firstMap.portals(sourceRect:CGRect(origin:origin,size:CGSize(width:1200,height:800))).isEmpty,"seeded origin touches receiver edge")
    }
    check(callbackCount>=1,"callback fired on first map adoption")

    // Stale revision ignored.
    let staleMap=ReceiverDesktop(revision:1,mainID:11,displays:[ReceiverDisplay(id:11,bounds:CGRect(x:9999,y:9999,width:1920,height:1080))])
    do {relay.adoptReceiverDesktopPayloadForTests(try mapPayload(staleMap))}catch{failures+=1}
    check(relay.receiverDesktop==firstMap,"stale revision ignored")

    // Same-revision divergent fingerprint rejected (protocol violation).
    let imposterSameRevision=ReceiverDesktop(revision:firstMap.revision,mainID:11,displays:[ReceiverDisplay(id:11,bounds:CGRect(x:100,y:100,width:1920,height:1080))])
    do {relay.adoptReceiverDesktopPayloadForTests(try mapPayload(imposterSameRevision))}catch{failures+=1}
    check(relay.receiverDesktop==firstMap,"same revision divergent map rejected")

    // Rearrangement at a newer revision: receiver desktop updates, source
    // origin re-anchored since the old origin no longer touches an edge.
    let movedDisplay=ReceiverDisplay(id:11,bounds:CGRect(x:-500,y:200,width:1920,height:1080),stableIdentity:mainReceiverDisplay.stableIdentity)
    let movedMap=ReceiverDesktop(revision:6,mainID:11,displays:[movedDisplay])
    let originBeforeMove=relay.sourceOrigin
    do {relay.adoptReceiverDesktopPayloadForTests(try mapPayload(movedMap))}catch{failures+=1}
    check(relay.receiverDesktop==movedMap,"newer revision adopts rearrangement")
    check(relay.sourceOrigin != nil,"source origin re-anchored to moved receiver")
    if let origin=relay.sourceOrigin {
        check(!movedMap.portals(sourceRect:CGRect(origin:origin,size:CGSize(width:1200,height:800))).isEmpty,"re-anchored origin touches receiver edge")
    }
    _ = originBeforeMove // used only to document intent; new origin may differ

    // Authenticated transport identity preserved across the map protocol.
    check(relay.connectionForTests === socket,"socket identity preserved")
    check(relay.contextForTests === context,"context identity preserved")
    check(!context.cancelled,"context not cancelled by map updates")
    check(relay.generation==originalGeneration,"generation preserved")
    check(relay.keyForTests?.withUnsafeBytes{Data($0)}==keyFingerprint,"key material preserved")

    // ------------------------------------------------------------------
    // 3) Explicit setSourceOrigin by the sender: validates against desktop,
    //    snaps, persists only when authenticated placement store has a pair.
    // ------------------------------------------------------------------
    let userProposed=CGPoint(x:-1300,y:250) // Not touching any receiver edge
    let changed=relay.setSourceOrigin(userProposed)
    check(changed,"setSourceOrigin accepted a valid proposal")
    if let accepted=relay.sourceOrigin {
        check(!movedMap.portals(sourceRect:CGRect(origin:accepted,size:CGSize(width:1200,height:800))).isEmpty,"user drag snaps to a valid portal")
    }
    // The UI's own left drag must not be mistaken for an unsafe remote drag.
    let alternate=CGPoint(x:movedDisplay.bounds.maxX,y:movedDisplay.bounds.minY)
    relay.desktopLocalButtonsForTests=[0]
    check(!relay.setSourceOrigin(alternate),"held button needs local layout gesture")
    check(relay.setSourceOrigin(alternate,fromLocalLayoutDrag:true),"actual local left layout drag accepted")
    relay.desktopLocalButtonsForTests=[1]
    check(!relay.setSourceOrigin(userProposed,fromLocalLayoutDrag:true),"other held buttons blocked")
    relay.desktopLocalButtonsForTests=[0];relay.desktopLocalKeysForTests=[12]
    check(!relay.setSourceOrigin(userProposed,fromLocalLayoutDrag:true),"held keys still block layout")
    relay.desktopLocalButtonsForTests=[];relay.desktopLocalKeysForTests=[]
    // User drag with the layoutDevicePair installed should have persisted.
    let restored=store.restored(for:pair,sourceSize:CGSize(width:1200,height:800),desktop:movedMap)
    check(restored != nil,"user drag persisted to placement store")
    // NaN origin rejected without side effect.
    let originBeforeBad=relay.sourceOrigin
    check(!relay.setSourceOrigin(CGPoint(x:Double.nan,y:0)),"NaN proposal rejected")
    check(relay.sourceOrigin==originBeforeBad,"NaN proposal does not mutate state")

    // ------------------------------------------------------------------
    // 4) New authenticated session on same pair restores saved placement
    //    on the first map adoption, without an auto-persist loop.
    // ------------------------------------------------------------------
    let fresh=Relay(desktopPlacementStore:store)
    fresh.senderForTests=true
    fresh.contextForTests=SessionContext(OwnedSocket(dup(fds[0])))
    fresh.connectionForTests=OwnedSocket(dup(fds[0]))
    fresh.keyForTests=SymmetricKey(size:.bits256)
    fresh.concurrentDisplayCompatibleForTests=true
    fresh.multiDisplayDesktopCompatibleForTests=true
    fresh.layoutDevicePairForTests=pair
    fresh.pendingInitialSourceOriginRestoreForTests=true
    fresh.topologyForTests=DisplayTopologySnapshot(mainID:1,activeIDs:[1],bounds:CGRect(x:0,y:0,width:1200,height:800))
    defer{fresh.contextForTests?.cancel(reason:"ReceiverDesktopRelayTests fresh fixture end")}
    do {fresh.adoptReceiverDesktopPayloadForTests(try mapPayload(movedMap))}catch{failures+=1}
    check(fresh.receiverDesktop==movedMap,"fresh session adopts map")
    check(fresh.sourceOrigin==restored,"fresh session restores saved placement")

    // ------------------------------------------------------------------
    // 5) Invalid or oversized map payloads must be dropped at adoption
    //    without clearing an already-accepted desktop or notifying UI.
    // ------------------------------------------------------------------
    let beforeInvalid=fresh.receiverDesktop
    let callbackBeforeInvalid=callbackCount
    fresh.adoptReceiverDesktopPayloadForTests(Data("not-json".utf8))
    check(fresh.receiverDesktop==beforeInvalid,"invalid payload leaves accepted desktop")
    check(callbackCount==callbackBeforeInvalid,"invalid payload does not fire callback")


    // Actual default adoption: initial physical-only source origin migrates to
    // the virtual-left edge when the owned display arrives, not an arbitrary snap.
    do {
        let defaultPair=LayoutDevicePair(localID:UUID().uuidString,peerID:UUID().uuidString)!
        let staged=Relay(desktopPlacementStore:store)
        staged.senderForTests=true;staged.connectionForTests=OwnedSocket(-1);staged.keyForTests=SymmetricKey(size:.bits256)
        staged.multiDisplayDesktopCompatibleForTests=true;staged.layoutDevicePairForTests=defaultPair
        staged.pendingInitialSourceOriginRestoreForTests=true
        staged.topologyForTests=DisplayTopologySnapshot(mainID:1,activeIDs:[1],bounds:CGRect(x:0,y:0,width:1200,height:800))
        staged.adoptReceiverDesktopPayloadForTests(try mapPayload(firstMap))
        check(staged.sourceOrigin==CGPoint(x:-1200,y:140),"initial default source left centered")
        let virt=ReceiverDisplay(id:12,bounds:CGRect(x:-1512,y:65,width:1512,height:950),stableIdentity:UUID().uuidString)
        let full=ReceiverDesktop(revision:6,mainID:11,displays:[mainReceiverDisplay,virt],virtualDisplayID:12)
        staged.adoptReceiverDesktopPayloadForTests(try mapPayload(full))
        check(staged.sourceOrigin==CGPoint(x:-2712,y:140),"virtual arrival migrates unsaved default to virtual left")
        check(store.restored(for:defaultPair,sourceSize:CGSize(width:1200,height:800),desktop:full)==nil,"automatic default adoption does not persist user source intent")
        let manual=CGPoint(x:1920,y:140)
        check(store.save(origin:manual,sourceSize:CGSize(width:1200,height:800),desktop:full,for:defaultPair),"save unrelated manual right attachment")
        let changed=ReceiverDesktop(revision:7,mainID:11,displays:[mainReceiverDisplay,virt],virtualDisplayID:12)
        staged.adoptReceiverDesktopPayloadForTests(try mapPayload(changed))
        // Same geometry/revision update need not reapply an external preference;
        // a new authenticated session proves saved placement wins over defaults.
        let restoredRelay=Relay(desktopPlacementStore:store)
        restoredRelay.senderForTests=true;restoredRelay.connectionForTests=OwnedSocket(-1);restoredRelay.keyForTests=SymmetricKey(size:.bits256)
        restoredRelay.multiDisplayDesktopCompatibleForTests=true;restoredRelay.layoutDevicePairForTests=defaultPair
        restoredRelay.pendingInitialSourceOriginRestoreForTests=true;restoredRelay.topologyForTests=staged.topologyForTests
        restoredRelay.adoptReceiverDesktopPayloadForTests(try mapPayload(full))
        check(restoredRelay.sourceOrigin==manual,"saved source placement wins over virtual-left default")

        let blockedPair=LayoutDevicePair(localID:UUID().uuidString,peerID:UUID().uuidString)!
        let blockedRelay=Relay(desktopPlacementStore:store)
        blockedRelay.senderForTests=true;blockedRelay.connectionForTests=OwnedSocket(-1);blockedRelay.keyForTests=SymmetricKey(size:.bits256)
        blockedRelay.multiDisplayDesktopCompatibleForTests=true;blockedRelay.layoutDevicePairForTests=blockedPair
        blockedRelay.pendingInitialSourceOriginRestoreForTests=true;blockedRelay.topologyForTests=staged.topologyForTests
        let p=ReceiverDisplay(id:31,bounds:CGRect(x:0,y:0,width:640,height:480)),l=ReceiverDisplay(id:32,bounds:CGRect(x:-640,y:0,width:640,height:480))
        let blockedMap=ReceiverDesktop(revision:1,mainID:31,displays:[p,l])
        blockedRelay.adoptReceiverDesktopPayloadForTests(try mapPayload(blockedMap))
        check(blockedRelay.sourceOrigin==CGPoint(x:-1840,y:-160),"physical-only main obstruction uses safe outside-map default")
        let newVirtual=ReceiverDisplay(id:33,bounds:CGRect(x:-1280,y:0,width:640,height:480))
        blockedRelay.adoptReceiverDesktopPayloadForTests(try mapPayload(ReceiverDesktop(revision:2,mainID:31,displays:[p,l,newVirtual],virtualDisplayID:33)))
        check(blockedRelay.sourceOrigin==CGPoint(x:-2480,y:-160),"virtual arrival moves outside-map default left of virtual")

        let rightPair=LayoutDevicePair(localID:UUID().uuidString,peerID:UUID().uuidString)!
        let rightRelay=Relay(desktopPlacementStore:store)
        rightRelay.senderForTests=true;rightRelay.connectionForTests=OwnedSocket(-1);rightRelay.keyForTests=SymmetricKey(size:.bits256)
        rightRelay.multiDisplayDesktopCompatibleForTests=true;rightRelay.layoutDevicePairForTests=rightPair
        rightRelay.pendingInitialSourceOriginRestoreForTests=true;rightRelay.topologyForTests=staged.topologyForTests
        let savedRightVirtual=ReceiverDisplay(id:12,bounds:CGRect(x:1920,y:65,width:1512,height:950),stableIdentity:UUID().uuidString)
        let rightMap=ReceiverDesktop(revision:1,mainID:11,displays:[mainReceiverDisplay,savedRightVirtual],virtualDisplayID:12)
        rightRelay.adoptReceiverDesktopPayloadForTests(try mapPayload(rightMap))
        check(rightRelay.sourceOrigin==CGPoint(x:-1200,y:140),"saved right virtual without saved source still seeds usable origin")
        check(rightRelay.sourceOrigin.map{!rightMap.portals(sourceRect:CGRect(origin:$0,size:CGSize(width:1200,height:800))).isEmpty}==true,"saved right virtual fallback has valid nonoverlapping portal")


    } catch {failures+=1}

    print("Receiver desktop relay integration: \(checks) checks failures=\(failures); no input, network, capture or keychain effects")
    return failures
}
