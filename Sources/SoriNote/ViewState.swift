import SwiftUI

// macOS 27 SDK에는 같은 이름의 State 매크로가 추가되어 있습니다.
// Command Line Tools만 설치한 환경에서도 기존 프로퍼티 래퍼를 분명히 선택합니다.
typealias ViewState<Value> = SwiftUI.State<Value>
