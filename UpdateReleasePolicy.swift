import Foundation

struct UpdateVersion:Comparable,Equatable {
  let numbers:[Int]
  let prerelease:[String]
  init?(_ tag:String) {
    guard !tag.isEmpty,tag.utf8.count<=80 else{return nil}
    let raw=tag.hasPrefix("v") ? String(tag.dropFirst()):tag
    let metadata=raw.split(separator:"+",omittingEmptySubsequences:false)
    guard metadata.count<=2 else{return nil}
    func identifiers(_ value:String)->[String]? {
      let parts=value.split(separator:".",omittingEmptySubsequences:false).map(String.init)
      guard parts.allSatisfy({!$0.isEmpty && $0.utf8.allSatisfy{(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)||$0==45}}) else{return nil}
      return parts
    }
    if metadata.count==2,identifiers(String(metadata[1]))==nil{return nil}
    let halves=metadata[0].split(separator:"-",maxSplits:1,omittingEmptySubsequences:false)
    let core=halves[0].split(separator:".",omittingEmptySubsequences:false)
    guard core.count==3,core.allSatisfy({!$0.isEmpty && ($0.count==1 || $0.first != "0") && $0.utf8.allSatisfy{(48...57).contains($0)}}) else{return nil}
    let values=core.compactMap{Int($0)};guard values.count==3 else{return nil}
    numbers=values
    if halves.count==2 {
      guard let ids=identifiers(String(halves[1])),ids.allSatisfy({!$0.utf8.allSatisfy{(48...57).contains($0)} || $0.count==1 || $0.first != "0"}) else{return nil}
      prerelease=ids
    } else {prerelease=[]}
  }
  static func ==(a:Self,b:Self)->Bool {a.numbers==b.numbers && a.prerelease==b.prerelease}
  static func <(a:Self,b:Self)->Bool {
    for (x,y) in zip(a.numbers,b.numbers) {if x != y{return x<y}}
    if a.prerelease.isEmpty{return false};if b.prerelease.isEmpty{return true}
    for (x,y) in zip(a.prerelease,b.prerelease) {
      if x==y {continue}
      let xn=x.utf8.allSatisfy{(48...57).contains($0)},yn=y.utf8.allSatisfy{(48...57).contains($0)}
      if xn && yn {return x.count==y.count ? x<y:x.count<y.count}
      if xn != yn{return xn};return x<y
    }
    return a.prerelease.count<b.prerelease.count
  }
}
struct UpdateRelease:Equatable {
  let tag:String
  let version:UpdateVersion
  var page:URL {URL(string:"https://github.com/2JIHAN/ThunderControl/releases/tag/"+tag)!}
}
enum UpdateReleasePolicy {
  static let maximumBytes=1024*1024
  static let endpoint=URL(string:"https://api.github.com/repos/2JIHAN/ThunderControl/releases?per_page=20")!
  enum Invalid:Error {case response}
  private struct Entry:Decodable {let tag_name:String?;let draft:Bool?}
  static func newest(data:Data,current:String)throws->UpdateRelease? {
    guard data.count<=maximumBytes,let local=UpdateVersion(current) else{throw Invalid.response}
    let entries=try JSONDecoder().decode([Entry].self,from:data)
    guard entries.count<=100 else{throw Invalid.response}
    return entries.compactMap{entry -> UpdateRelease? in
      guard entry.draft != true,let tag=entry.tag_name,let version=UpdateVersion(tag),version>local else{return nil}
      return UpdateRelease(tag:tag,version:version)
    }.max{$0.version<$1.version}
  }
  static func shouldAutomaticallyCheck(now:Double,last:Double)->Bool {
    now.isFinite && now>0 && (!last.isFinite || last<=0 || now<last || now-last>=24*60*60)
  }
}
