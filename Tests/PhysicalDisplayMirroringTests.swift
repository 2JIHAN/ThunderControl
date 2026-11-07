import Foundation

@discardableResult func runPhysicalDisplayMirroringTests() -> Int {
    typealias S = PhysicalDisplayMirroring
    let latest = S.Mode(width: 2560, height: 1440, pixelWidth: 2560, pixelHeight: 1440, hz: 60, flags: 1)
    let fallback = S.Mode(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, hz: 30, flags: 1)
    func display(_ id: UInt32, _ mirror: UInt32 = 0, active: Bool = true) -> S.Display {
        S.Display(id: id, uuid: "physical-\(id)", vendor: 10, model: id, serial: id,
                  active: active, bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440), mirror: mirror, mode: latest)
    }
    let saved = S(displays: [display(11), display(22, 33, active: false), display(33)], mainID: 11, ownedPresent: true)
    var current = saved
    current.ownedPresent = false
    var failures = 0
    func expect(_ ok: Bool, _ name: String) {
        if !ok { failures += 1; print("FAIL physical mirroring: \(name)") }
    }
    expect(saved.repairPlan(current: current) == [], "unchanged needs no writes")
    current.displays[1].mirror = 0
    current.displays[1].active = true
    current.displays[1].mode = fallback
    current.displays[1].bounds.origin.x = -1920
    let lost = current
    let plan = saved.repairPlan(current: lost)
    expect(plan == [S.Repair(aliasID: 22, rootID: 33)], "normal alias loss restores only existing relation")
    expect(saved.displays[2].mode == latest && plan?.first?.rootID == 33, "latest 2560 root selected, not startup mode")
    func deny(_ name: String, _ change: (inout S) -> Void) {
        var changed = lost; change(&changed)
        expect(saved.repairPlan(current: changed) == nil, name)
    }
    deny("added participant") { $0.displays.append(display(44)) }
    deny("missing participant") { $0.displays.removeLast() }
    deny("reused ID") { $0.displays[1].uuid = "replacement" }
    deny("vendor changed") { $0.displays[1].vendor += 1 }
    deny("model changed") { $0.displays[1].model += 1 }
    deny("serial changed") { $0.displays[1].serial += 1 }
    deny("main changed") { $0.mainID = 33 }
    deny("root origin changed") { $0.displays[2].bounds.origin.x = 1 }
    deny("root mode changed") { $0.displays[2].mode = fallback }
    deny("root inactive") { $0.displays[2].active = false }
    deny("new mirror target") { $0.displays[1].mirror = 11 }
    deny("owned still present") { $0.ownedPresent = true }
    deny("mirror to excluded owned display") { $0.displays[1].mirror = 99 }
    deny("cycle") { $0.displays[0].mirror = 33; $0.displays[2].mirror = 11 }
    deny("duplicate ID") { $0.displays[1].id = 11 }
    var invalidSaved = saved
    invalidSaved.ownedPresent = false
    expect(invalidSaved.repairPlan(current: lost) == nil, "capture requires owned present")
    invalidSaved = saved; invalidSaved.displays[1].mirror = 99
    expect(invalidSaved.repairPlan(current: lost) == nil, "invalid saved graph")
    var aliasChanged = saved; aliasChanged.ownedPresent = false; aliasChanged.displays[1].mode = fallback
    expect(saved.repairPlan(current: aliasChanged) == nil, "unchanged mirror with changed state denied")
    print("PhysicalDisplayMirroringTests: \(failures) failures")
    return failures
}
