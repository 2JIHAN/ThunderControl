# Mac 사이에 폴더 보내기

ThunderControl 0.9.10부터 파일 하나와 같은 방법으로 폴더 하나를 보낼 수 있습니다. 두 Mac 모두 0.9.10 이상이어야 하며, 한쪽이 0.9.9이면 파일 전송은 그대로 되지만 폴더를 보내려 하면 두 Mac 모두 0.9.10이 필요하다는 안내가 나옵니다.

1. 보내는 Mac의 **파일** 탭에 폴더를 끌어놓거나 **파일 또는 폴더 선택…**을 누르세요.
2. 받는 Mac에 폴더 이름, 파일 수와 전체 크기가 표시됩니다. **수락하고 저장…**을 누르고 새 폴더의 위치와 이름을 선택하세요.
3. 양쪽에 전체 진행률, 완료한 파일 수와 현재 파일이 표시됩니다.

## 중단과 이어받기

**전송 중단**이나 연결 끊김, 앱 종료로 멈춰도 이미 완료한 파일은 남습니다. 이어서 받으려면 바뀌지 않은 같은 폴더를 다시 보내고, 받는 Mac에서 **같은 위치와 같은 이름**을 선택하세요. 완료한 파일은 다시 보내지 않고, 멈출 때 받던 파일만 처음부터 다시 받습니다. 파일 중간부터 이어받지는 않습니다.

받는 동안 선택한 위치에는 다음 두 항목이 보입니다.

- `이름.partial`: 받는 중인 폴더입니다. 모두 받으면 `이름`으로 바뀝니다.
- `이름.partial.journal`: 이어받기 기록입니다. 완료 확인 후 지웁니다.

이어받기는 같은 두 Mac(인증된 기기 ID), 같은 원본 목록, 같은 저장 위치와 이름일 때만 됩니다. 원본 폴더 안의 파일이나 폴더가 바뀌면(Finder가 `.DS_Store`를 만드는 경우 포함) 새 전송으로 보고 다른 이름을 선택해야 합니다. 이어받기를 포기하려면 두 항목을 직접 지우세요.

## 범위

- 일반 파일과 폴더, 빈 폴더, 빈 파일과 숨김 파일을 보냅니다. 심볼릭 링크와 특수 파일이 있으면 그 경로를 알려 주고 보내지 않습니다.
- 파일 하나는 최대 64GiB입니다. 폴더 전체 크기에는 별도 64GiB 한도가 없습니다(예: 63GB 파일 100개). 항목은 최대 100,000개, 경로 깊이는 128단계입니다.
- 기존 폴더와 합치거나 덮어쓰지 않습니다. 같은 이름이 있으면 다른 이름을 선택하세요. 받은 파일에는 macOS 격리 보안을 적용합니다.
- 권한, 확장 속성, 리소스 포크와 링크는 복제하지 않습니다. 파일을 하나씩 순서대로 보냅니다.

## 개발자용 구조

| 파일 | 책임 |
| --- | --- |
| `FolderManifest.swift` | 검증된 상대 경로, 변경 불가 manifest와 canonical digest, 원본 snapshot(`FolderSourcePlan`) |
| `FolderReceiverStore.swift` | 받는 쪽 경로, journal, crash 복구와 게시를 소유 |
| `FolderTransferEngine.swift` | `FolderMessage`와 순차 프로토콜, heartbeat 대기 |
| `FileTransfer.swift` | 인증된 파일 채널 adapter, 승인과 서비스 연결 |

세 폴더 모듈은 Foundation, CryptoKit, Darwin만 사용합니다. 키와 소켓은 `FileChannel` 안에 남고, 엔진은 `FolderChannel` 프로토콜만 봅니다.

```swift
let plan = try FolderSourcePlan.capture(folderURL)
try FolderTransferEngine.send(plan, over: channel, check: check, report: report)
try FolderTransferEngine.receive(offer, over: channel, identity: FolderPeerIdentity(local: me, peer: peer),
                                 choose: { check in approvedURL }, check: check, report: report)
```

### 프로토콜

파일 v1의 nonce, proof, frame 형식과 키는 바꾸지 않습니다. 인증 hello의 별도 `folderTransferCodec: 1`에 양쪽이 동의했을 때만 `FilePacket(kind: "folder", folder: FolderMessage)`를 처리합니다. `folder` 필드는 한 번만 JSON으로 인코딩하며 64KiB 데이터도 기존 100,000바이트 frame 안에 들어갑니다. manifest는 60,000바이트 조각으로 나눠 보내고 받는 쪽은 받은 바이트 그대로 SHA-256을 확인합니다.

순서는 offer, accept, manifest, plan(필요한 파일 bitmap), 파일마다 fileBegin, data, fileEnd와 fileDone, finish, complete, closed입니다. 긴 승인, 해시, fsync와 게시 중에는 작업 스레드가 일하는 동안 채널 스레드 하나만 2초마다 `working`을 보내 기존 15초 소켓 timeout을 유지합니다. 대기 단계마다 진행이 없으면 600초, 승인은 130초에 끝납니다.

### 저장과 복구 순서

1. journal header에 로컬/상대 기기 ID, manifest digest, 부모 폴더와 stage inode, 최종 이름을 기록합니다.
2. 임시 파일을 만든 직후 이름과 inode를 `begin`으로 기록한 뒤 데이터를 받습니다.
3. SHA가 맞으면 `expect`(SHA와 임시 inode)를 먼저 기록하고 격리 속성, fsync와 RENAME_EXCL로 게시합니다.
4. 게시 후 stat을 `done`으로 fsync한 다음 fileDone을 보냅니다.
5. 모두 받으면 `publishIntent`를 기록하고, stage 트리가 manifest와 정확히 같은지(숨김 파일과 폴더 포함, 링크를 따라가지 않음) 확인하고, stage identity를 확인한 뒤 폴더를 RENAME_EXCL로 바꾸고 `published`를 기록합니다.

재개할 때 journal은 신뢰하지 않는 metadata로 읽습니다. `done` 파일은 stat이 같으면 건너뛰고, 다르면 기록한 SHA로 다시 해시합니다. `expect`만 있으면 같은 inode와 SHA일 때만 채택합니다. 기록과 identity가 맞는 임시 파일만 지우고, 모르는 항목은 지우거나 채택하지 않고 충돌로 멈춥니다. 최종 이름의 폴더는 기록한 stage inode와 모든 receipt가 맞고 manifest에 없는 항목이 하나도 없을 때만 완료로 인정합니다. manifest에 없는 파일, 링크, 폴더, 기록되지 않은 `.thundercontrol-UUID.partial`은 옮기거나 지우지 않고 충돌로 멈춥니다. 알려진 한계: 임시 파일을 만든 직후 `begin` 기록 전에 종료되면 그 빈 임시 파일이 남고, 이어받기는 게시 전에 그 이름으로 충돌을 알립니다. 사용자가 직접 지워야 합니다.

원본 스냅샷에서 폴더(루트 포함)는 dev/inode만 버전으로 씁니다. NSOpenPanel이 붙이는 `com.apple.macl` 같은 xattr은 폴더 ctime을 바꾸지만 내용은 바꾸지 않기 때문입니다. 항목 추가, 삭제, 이름 변경은 manifest의 이름 목록으로, 폴더 교체는 inode로, 파일 변경은 파일의 전체 stat(ctime 포함)으로 잡습니다.

### 검사

```sh
scripts/test-folder.sh                       # 폴더 모듈 단독 검사 (AppKit 미링크 확인)
xcrun swiftc -swift-version 5 -parse-as-library -D FILE_TRANSFER_SELF_TEST \
  Localization.swift FileTransferStorage.swift FolderManifest.swift FolderReceiverStore.swift \
  FolderTransferEngine.swift FileTransfer.swift Tests/FileTransferTests.swift \
  -framework CryptoKit -framework Security -o /tmp/thundercontrol-file-tests
/tmp/thundercontrol-file-tests               # 파일 v1과 실제 localhost 폴더 서비스
```

단독 검사는 경로와 충돌 규칙, 원본 교체와 링크/FIFO, 왕복, ACK 손실, 취소 후 재개, 다른 상대 거부, 마지막 ACK 손실, 다섯 crash 지점, 관련 없는 최종 폴더, receipt 재해시, 승인 콜백 중 교체, heartbeat와 stall, sparse 100 x 63GB 목록과 용량 사전 검사를 확인합니다. 서비스 검사는 실제 암호화 localhost 연결로 양방향 전송, 새 세션 키에서 이어받기, busy와 0.9.9 상대를 확인합니다.

실제 두 Mac 사이의 전송과 실제 드래그 조작은 아직 확인하지 않았습니다.

## 적용한 원칙

- Model the Domain: 변경 불가 manifest, 형식이 있는 `FolderMessage`, 받는 쪽 경로와 journal의 단일 소유자를 둡니다.
- Make Operations Idempotent: 완료 표시를 믿지 않고 실제 파일, inode와 SHA를 WAL과 대조해 같은 전송을 다시 실행해도 결과가 같습니다.
