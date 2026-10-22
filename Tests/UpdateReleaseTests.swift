import Foundation
func runUpdateReleaseTests()->Int {
  var checks=0,failures=0
  func expect(_ value:Bool){checks+=1;if !value{failures+=1}}
  let ordered=["0.8.28-alpha","0.8.28-alpha.1","0.8.28-alpha.beta","0.8.28-beta","0.8.28-beta.2","0.8.28-beta.11","0.8.28-rc.1","0.8.28","0.8.29","0.8.30","0.8.30.1","0.8.30.2","0.8.30.10","0.8.31","0.9.0","1.0.0"]
  for i in 0..<ordered.count {for j in 0..<ordered.count {
    expect((UpdateVersion(ordered[i])!<UpdateVersion(ordered[j])!) == (i<j))
  }}
  expect(UpdateVersion("v0.8.28")==UpdateVersion("0.8.28+build.58"))
  for tag in ["","v","V1.2.3","1.2","1.2.3.4.5","1.2.3.04","1.02.3","01.2.3","1.2.-1","1.2.3-","1.2.3-01","1.2.3+","1.2.3-x..y","1.2.3/evil","1.2.3#evil","1.2.3?evil","1.2.3%2Fevil","https://evil.com","1.2.3+foo+bar",String(repeating:"9",count:85),"999999999999999999999999999.2.3"] {expect(UpdateVersion(tag)==nil)}
  expect(UpdateVersion("0.8.30")==UpdateVersion("0.8.30.0"))
  func data(_ object:Any)->Data {try! JSONSerialization.data(withJSONObject:object)}
  let fixture:[[String:Any]]=[
    ["tag_name":"v0.8.27","draft":false],
    ["tag_name":"v0.8.28","draft":false,"prerelease":true,"html_url":"https://evil.example/payload"],
    ["tag_name":"v0.8.29-rc.1","draft":false,"prerelease":true],
    ["tag_name":"v9.0.0","draft":true],
    ["tag_name":"bad","draft":false],
    ["name":"missing optional tag"]]
  do {
    expect(try UpdateReleasePolicy.newest(data:data([["tag_name":"v0.8.30.1","draft":false]]),current:"0.8.30")?.tag=="v0.8.30.1")
    expect(try UpdateReleasePolicy.newest(data:data([["tag_name":"v0.8.30.1","draft":false]]),current:"0.8.31")==nil)
    let newer=try UpdateReleasePolicy.newest(data:data(fixture),current:"0.8.27")
    expect(newer?.tag=="v0.8.29-rc.1")
    expect(newer?.page.absoluteString=="https://github.com/2JIHAN/ThunderControl/releases/tag/v0.8.29-rc.1")
    let poisoned=try UpdateReleasePolicy.newest(data:data([fixture[1]]),current:"0.8.27")
    expect(poisoned?.page.host=="github.com")
    expect(poisoned?.page.path=="/2JIHAN/ThunderControl/releases/tag/v0.8.28")
    expect(try UpdateReleasePolicy.newest(data:data([fixture[1]]),current:"0.8.28")==nil)
    expect(try UpdateReleasePolicy.newest(data:data([fixture[1]]),current:"0.8.29")==nil)
    expect(try UpdateReleasePolicy.newest(data:data([]),current:"0.8.28")==nil)
    expect(try UpdateReleasePolicy.newest(data:data([["tag_name":"v0.8.29"]]),current:"0.8.28")?.tag=="v0.8.29")
  }catch{expect(false)}
  for bad in [Data(repeating:32,count:UpdateReleasePolicy.maximumBytes+1),Data("{}".utf8),data(Array(repeating:["tag_name":"v0.8.29"],count:101))] {
    do {_ = try UpdateReleasePolicy.newest(data:bad,current:"0.8.28");expect(false)}catch{expect(true)}
  }
  expect(UpdateReleasePolicy.endpoint.host=="api.github.com")
  expect(UpdateReleasePolicy.endpoint.path.hasSuffix("/releases"))
  expect(UpdateReleasePolicy.shouldAutomaticallyCheck(now:100,last:0))
  expect(!UpdateReleasePolicy.shouldAutomaticallyCheck(now:101,last:100))
  expect(UpdateReleasePolicy.shouldAutomaticallyCheck(now:86500,last:100))
  expect(UpdateReleasePolicy.shouldAutomaticallyCheck(now:90,last:100))
  expect(!UpdateReleasePolicy.shouldAutomaticallyCheck(now:.nan,last:0))
  print("Update release policy: \(checks) checks, \(failures) failures; fixtures only, no network/preferences/installation")
  return failures
}
