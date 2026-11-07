import AppKit

@MainActor func runBoundaryReadinessTests()->Int {
  guard Relay.verifyBoundaryReadinessForTests() else {
    print("FAIL boundary readiness and actual desktop detector fixture")
    return 1
  }
  print("PASS boundary readiness, shared geometry, display ordinal versus ID, unavailable and entry guards; memory only")
  return 0
}
