# 셔터링크 (ShutterLink) — iOS 블루투스 카메라 리모컨

카메라에 이미 들어 있는 **순정 블루투스 리모컨 기능**(소니 RMT-P1BT, 캐논 BR-E1, 니콘 ML-L7)에
아이폰이 리모컨인 척 붙어서 셔터만 빠르게 누르는 앱입니다. 라이브뷰·Wi-Fi를 쓰지 않으므로 브랜드 앱보다 훨씬 빨리 연결됩니다.

| 카메라 | 방식 | 상태 |
|---|---|---|
| 소니 a6400, A7C II | RMT-P1BT 프로토콜 | 공개 자료·실사용 앱 다수, 가장 확실 |
| 캐논 PowerShot V1 | BR-E1 프로토콜 | EOS 계열에서 검증된 방식, V1 실기 확인 필요 |
| 니콘 Zf | ML-L7 프로토콜 | Z6 III에서 검증된 방식, Zf 실기 확인 필요 |
| 소니 a6000 | — | 블루투스가 없어 이 앱으로는 불가 (Wi-Fi 전용) |

## 빌드해서 아이폰에 설치하기

1. **Xcode 16 이상**에서 `ShutterLink.xcodeproj`를 엽니다.
2. 왼쪽에서 `ShutterLink` 프로젝트 → 타깃 `ShutterLink` → **Signing & Capabilities**
   - **Team**: 내 Apple ID 선택 (무료 계정도 됨)
   - **Bundle Identifier**: `com.yourname.shutterlink`의 `yourname`을 아무 고유한 값으로 변경
3. 아이폰을 케이블로 연결하고 상단에서 기기로 선택 → ▶︎ 실행
   - 처음이면 아이폰 **설정 > 개인정보 보호 및 보안 > 개발자 모드**를 켜야 합니다.
   - 무료 계정으로 설치하면 7일 후 다시 실행(설치)해야 합니다.
4. 시뮬레이터에서는 블루투스가 동작하지 않습니다. 반드시 실제 아이폰에서 테스트하세요.

## 사용법

1. 오른쪽 위 **+** → 기종 탭에서 카메라 메뉴 순서를 보고 카메라를 **리모컨 페어링 대기** 상태로 만듭니다.
2. 목록에 뜬 카메라를 탭 → 아이폰의 **블루투스 페어링 요청**에서 '페어링' → 카메라에 확인이 뜨면 OK.
3. 등록이 끝나면 다음부터는 **카메라 전원만 켜면 자동 연결**됩니다 (앱이 백그라운드여도 연결은 유지).

**셔터 버튼**
- 손가락이 닿는 순간 셔터 누름, 떼는 순간 뗌 → 짧게 탭하면 한 장, 길게 누르면 연사/벌브
- 소니는 AF가 끝나 셔터가 실제로 열릴 때까지 버튼을 자동으로 유지하고, 촬영되면 화면이 번쩍 + 진동
- 셀프타이머 2/5/10초: 눌렀다 떼면 카운트다운, 카운트다운 중 다시 누르면 취소
- 여러 대를 등록하면 체크된 카메라가 **동시에** 찍힙니다 (카메라 줄을 탭해서 켜기/끄기)
- 카메라 줄을 길게 누르면: 다시 연결 / 이름 바꾸기 / 삭제

## 실기 테스트 체크리스트

카메라마다 아래 순서로 확인해 주세요. 막히면 앱에 표시된 **빨간 상태 문구**를 그대로 알려주시면 원인을 좁힐 수 있습니다.

1. 페어링 목록에 카메라가 뜨는가 (안 뜨면: 카메라 메뉴가 '스마트폰 연결'이 아니라 '리모컨' 페어링인지)
2. 탭 → '촬영 가능'까지 가는가
3. 셔터가 눌리는가 (탭 1회 = 1장)
4. 카메라를 껐다 켜면 자동으로 '촬영 가능'으로 돌아오는가
5. 앱을 껐다 켜도 자동 연결되는가
6. 거리 테스트: 시야가 트인 곳에서 몇 m까지 되는가

특히 **캐논 V1**은 아이폰과의 보안 페어링(본딩) 방식이, **니콘 Zf**는 인증 핸드셰이크가 실기에서 처음 검증됩니다.

## 코드 구조

```
ShutterLink/
  App/ShutterLinkApp.swift      앱 진입점, 진동
  BLE/BLEController.swift       스캔·연결·자동 재연결·페어링 상태 관리 (CBCentralManager)
  BLE/CameraSession.swift       카메라 1대의 연결 상태 + 셔터 명령 직렬 큐
  BLE/PeripheralLink.swift      GATT 작업을 async/await로 감싼 래퍼
  BLE/OneShot.swift             콜백 1회 대기(타임아웃 포함), 오류 정의
  Cameras/SonyDriver.swift      소니 RMT-P1BT 프로토콜
  Cameras/CanonDriver.swift     캐논 BR-E1 프로토콜
  Cameras/NikonDriver.swift     니콘 ML-L7 프로토콜 (4단계 인증 핸드셰이크)
  Cameras/AdvertisementParser.swift  광고 패킷으로 브랜드·페어링 상태 판별
  Cameras/CameraBrand.swift     브랜드별 페어링 안내 문구
  Model/SavedCamera.swift       등록된 카메라 저장 (UserDefaults)
  Views/                        메인 화면, 셔터 버튼, 페어링·설정 화면
Support/Info.plist              백그라운드 블루투스 모드
```

브랜드 프로토콜은 `CameraDriver` 프로토콜(setUp / press / release) 하나로 추상화되어 있어,
나중에 맥 앱(SwiftUI 멀티플랫폼)·애플워치에서 `BLE/`와 `Cameras/` 폴더를 그대로 재사용할 수 있습니다.

## 프로토콜 출처

- 소니: [freemote](https://github.com/coral/freemote), [Greg Leeds](https://gregleeds.com/reverse-engineering-sony-camera-bluetooth/), [gethypoxic](https://gethypoxic.com/blogs/technical/sony-camera-ble-control-protocol-di-remote-control)
- 캐논: [eos-remote-web](https://github.com/RReverser/eos-remote-web) (MIT), Ian Douglas Scott의 분석
- 니콘·전체: [furble](https://github.com/gkoh/furble) (MIT)
- [α-Remote](https://github.com/Staacks/alpharemote)(GPL-3.0)는 동작 확인용으로만 참고했고 코드는 가져오지 않았습니다.

각 제조사와 무관한 비공식 앱입니다.
