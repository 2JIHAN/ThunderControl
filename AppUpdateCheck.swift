import AppKit
import Foundation

/// Public metadata only. No cookies, credentials, redirects, downloads or installation.
final class UpdateHTTPClient:NSObject,URLSessionDataDelegate {
  private var session:URLSession?
  private var bytes=Data(),validResponse=false
  private var completion:((Result<Data,Error>)->Void)?
  func start(_ completion:@escaping(Result<Data,Error>)->Void) {
    self.completion=completion
    let config=URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest=15;config.timeoutIntervalForResource=20
    config.httpShouldSetCookies=false;config.httpCookieStorage=nil;config.urlCredentialStorage=nil;config.urlCache=nil
    let queue=OperationQueue();queue.maxConcurrentOperationCount=1
    let session=URLSession(configuration:config,delegate:self,delegateQueue:queue);self.session=session
    var request=URLRequest(url:UpdateReleasePolicy.endpoint,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:15)
    request.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept")
    request.setValue("ThunderControl-UpdateCheck",forHTTPHeaderField:"User-Agent")
    session.dataTask(with:request).resume()
  }
  func cancel(){session?.invalidateAndCancel()}
  func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){completionHandler(nil)}
  func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,completionHandler:@escaping(URLSession.ResponseDisposition)->Void) {
    guard let response=response as? HTTPURLResponse,response.statusCode==200,
      response.url?.scheme=="https",response.url?.host=="api.github.com",
      response.expectedContentLength<=Int64(UpdateReleasePolicy.maximumBytes) else{completionHandler(.cancel);return}
    validResponse=true;completionHandler(.allow)
  }
  func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data) {
    guard bytes.count<=UpdateReleasePolicy.maximumBytes-data.count else{validResponse=false;dataTask.cancel();return}
    bytes.append(data)
  }
  func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) {
    let result:Result<Data,Error> = error.map{.failure($0)} ?? (validResponse ? .success(bytes):.failure(UpdateReleasePolicy.Invalid.response))
    let callback=completion;completion=nil;session.finishTasksAndInvalidate()
    DispatchQueue.main.async {callback?(result)}
  }
}

@MainActor final class AppUpdateCheck:NSObject,NSMenuItemValidation {
  let checkItem=NSMenuItem(title:TCText("Check for Updates…"),action:nil,keyEquivalent:"")
  let availableItem=NSMenuItem(title:TCText("New version available"),action:nil,keyEquivalent:"")
  private var client:UpdateHTTPClient?,generation=UUID(),manualRequested=false,stopped=false
  private var available:UpdateRelease?
  private let current=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "0.0.0"
  private static let lastKey="ThunderControl.updateCheck.lastAttempt",availableKey="ThunderControl.updateCheck.availableTag"
  override init(){
    super.init()
    checkItem.target=self;checkItem.action=#selector(manualCheck)
    availableItem.target=self;availableItem.action=#selector(openRelease);availableItem.isHidden=true
  }
  func startAutomatically(){
    guard !CommandLine.arguments.dropFirst().contains(where:{$0.hasPrefix("--")}) else{return}
    if let tag=UserDefaults.standard.string(forKey:Self.availableKey),let version=UpdateVersion(tag),let local=UpdateVersion(current),version>local {setAvailable(.init(tag:tag,version:version))}
    let now=Date().timeIntervalSince1970
    if UpdateReleasePolicy.shouldAutomaticallyCheck(now:now,last:UserDefaults.standard.double(forKey:Self.lastKey)) {check(manual:false)}
  }
  func stop(){stopped=true;generation=UUID();client?.cancel();client=nil}
  func validateMenuItem(_ menuItem:NSMenuItem)->Bool {menuItem===checkItem ? client==nil && !stopped:available != nil && !stopped}
  @objc func manualCheck(){check(manual:true)}
  private func check(manual:Bool){
    guard !stopped,!CommandLine.arguments.dropFirst().contains(where:{$0.hasPrefix("--")}) else{return}
    if client != nil {manualRequested = manualRequested || manual;return}
    manualRequested=manual;let token=UUID();generation=token
    UserDefaults.standard.set(Date().timeIntervalSince1970,forKey:Self.lastKey)
    let client=UpdateHTTPClient();self.client=client;checkItem.title=TCText("Checking for updates…")
    client.start{[weak self] result in
      MainActor.assumeIsolated {
        guard let self,!self.stopped,self.generation==token else{return}
        self.client=nil;self.checkItem.title=TCText("Check for Updates…")
        let manual=self.manualRequested;self.manualRequested=false
        do {
          let release=try UpdateReleasePolicy.newest(data:result.get(),current:self.current)
          self.setAvailable(release)
          if let release {UserDefaults.standard.set(release.tag,forKey:Self.availableKey)}else{UserDefaults.standard.removeObject(forKey:Self.availableKey)}
          if manual {self.showResult(release:release,error:false)}
        }catch{if manual {self.showResult(release:nil,error:true)}}
      }
    }
  }
  private func setAvailable(_ release:UpdateRelease?){
    available=release;availableItem.isHidden=release==nil
    if let release {availableItem.title=TCText("Version {0} available…",release.tag)}
  }
  private func showResult(release:UpdateRelease?,error:Bool){
    let alert=NSAlert()
    alert.messageText=error ? TCText("Could not check for updates") : (release != nil ? TCText("New version available"):TCText("You are up to date"))
    alert.informativeText=error ? TCText("Check your Internet connection and try again later. GitHub may temporarily limit requests.") : (release.map{TCText("Version {0} is available. Open its GitHub release page to review and download it. The app will not install updates automatically.",$0.tag)} ?? TCText("Current version: {0}. Published prereleases are included.",current))
    if release != nil {alert.addButton(withTitle:TCText("Open Release Page"));alert.addButton(withTitle:TCText("Not Now"))}else{alert.addButton(withTitle:TCText("OK"))}
    if alert.runModal() == .alertFirstButtonReturn,let release {NSWorkspace.shared.open(release.page)}
  }
  @objc func openRelease(){guard !stopped,let release=available else{return};NSWorkspace.shared.open(release.page)}
}
