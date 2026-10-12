import Foundation

/// 실행 환경 선택과 다운로드 설정은 모델 설정과 분리합니다. 비밀번호·토큰은 저장하지 않습니다.
enum RuntimeMode: String, Codable, CaseIterable, Identifiable {
    case automatic, localPython, existingVenv, download
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "자동 선택 · 설치된 Python 우선"
        case .localPython: "기존 Python으로 전용 venv 생성"
        case .existingVenv: "준비된 venv 연결"
        case .download: "전용 Python 다운로드"
        }
    }
}

struct RuntimeSettings: Codable, Equatable {
    var mode: RuntimeMode = .automatic
    var sourcePython = ""
    var allowPythonDownload = true
    var installMissingPackages = false
    var network = DownloadSettings()
}

/// 비어 있는 칸은 앱을 실행한 환경의 설정을 사용합니다. Finder 실행에는 터미널의 export가 전달되지 않습니다.
struct DownloadSettings: Codable, Equatable {
    var useSystemCertificates = true
    var caBundlePath = ""
    var proxyURL = ""
    var pythonMirrorURL = ""
    var packageIndexURL = ""
    var wheelhousePath = ""
    var offline = false

    func validate() throws {
        let fm = FileManager.default
        for (label, path) in [("CA 인증서", caBundlePath), ("오프라인 패키지 폴더", wheelhousePath)] where !path.isEmpty {
            guard path.hasPrefix("/"), fm.isReadableFile(atPath: path) else {
                throw AppFailure(message: "\(label)의 읽을 수 있는 절대 경로를 입력하세요.")
            }
            var isDirectory: ObjCBool = false
            _ = fm.fileExists(atPath: path, isDirectory: &isDirectory)
            guard isDirectory.boolValue == (label == "오프라인 패키지 폴더") else {
                throw AppFailure(message: "\(label)의 파일·폴더 형식을 확인하세요.")
            }
        }
        for (label, address) in [("프록시", proxyURL), ("Python 미러", pythonMirrorURL), ("패키지 저장소", packageIndexURL)] where !address.isEmpty {
            guard let url = URLComponents(string: address), url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil,
                  ((label == "Python 미러" && url.scheme == "file" && url.path.hasPrefix("/")) ||
                   (["https", "http"].contains(url.scheme ?? "") && !(url.host ?? "").isEmpty)) else {
                throw AppFailure(message: "\(label) 주소를 확인하세요. 주소 안에 비밀번호·토큰을 넣을 수 없습니다. 인증은 회사에서 제공한 환경 변수나 도구 설정을 사용하세요.")
            }
            if url.scheme == "http", label != "프록시", !["127.0.0.1", "localhost", "::1"].contains(url.host ?? "") {
                throw AppFailure(message: "\(label)는 HTTPS 주소를 사용하세요. 사내 HTTP 저장소는 보안 담당자와 확인 후 uv 설정에서 지정할 수 있습니다.")
            }
        }
    }

    /// 설치 대상 경로를 바꿀 수 있는 옵션만 제외하고 인증서·프록시·미러 관련 설정은 이어받습니다.
    func environment(inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = inherited
        for key in ["PYTHONPATH", "PYTHONHOME", "UV_SYSTEM_PYTHON", "UV_BREAK_SYSTEM_PACKAGES", "UV_TARGET", "UV_PREFIX",
                    "PIP_TARGET", "PIP_PREFIX", "PIP_USER", "UV_PYTHON", "UV_PYTHON_ENVIRONMENT", "UV_PROJECT_ENVIRONMENT"] {
            env.removeValue(forKey: key)
        }
        env["UV_SYSTEM_CERTS"] = useSystemCertificates ? "true" : "false"
        env["SORINOTE_SYSTEM_CERTS"] = useSystemCertificates ? "1" : "0"
        if !caBundlePath.isEmpty {
            for key in ["SSL_CERT_FILE", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE"] { env[key] = caBundlePath }
            env.removeValue(forKey: "SSL_CERT_DIR")
        } else if let ca = env["SSL_CERT_FILE"], !ca.isEmpty {
            // requests 계열과 httpx/uv가 같은 인증서 묶음을 사용하게 합니다.
            env["REQUESTS_CA_BUNDLE"] = ca
        }
        if !proxyURL.isEmpty {
            for key in ["HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy"] { env[key] = proxyURL }
        }
        let bypass = (env["NO_PROXY"] ?? env["no_proxy"] ?? "").split(separator: ",").map(String.init)
        let noProxy = (bypass + ["localhost", "127.0.0.1", "::1"]).joined(separator: ",")
        env["NO_PROXY"] = noProxy; env["no_proxy"] = noProxy
        if !pythonMirrorURL.isEmpty { env["UV_PYTHON_INSTALL_MIRROR"] = pythonMirrorURL }
        if !packageIndexURL.isEmpty {
            // 환경 변수의 옛 인덱스 주소보다 화면에서 지정한 기본 저장소를 우선합니다.
            // uv 설정 파일의 추가 인덱스까지 없애지는 않습니다. 사내 전용 설치는 그 파일도 확인하세요.
            for key in ["UV_INDEX", "UV_EXTRA_INDEX_URL", "UV_INDEX_URL"] { env.removeValue(forKey: key) }
            env["UV_DEFAULT_INDEX"] = packageIndexURL
        } else if env["UV_DEFAULT_INDEX"] == nil, env["UV_INDEX_URL"] == nil, let index = env["PIP_INDEX_URL"] {
            env["UV_DEFAULT_INDEX"] = index
        }
        if env["UV_FIND_LINKS"] == nil, let links = env["PIP_FIND_LINKS"] { env["UV_FIND_LINKS"] = links }
        if !wheelhousePath.isEmpty { env["UV_FIND_LINKS"] = wheelhousePath; env["UV_NO_INDEX"] = "true" }
        if offline { env["UV_OFFLINE"] = "true"; env["SORINOTE_OFFLINE"] = "1"; env["HF_HUB_OFFLINE"] = "1" }
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["PYANNOTE_METRICS_ENABLED"] = "0"
        env["DO_NOT_TRACK"] = "1"
        return env
    }
}

/// 외부 도구의 출력에는 서명된 URL이나 프록시 인증 정보가 섞일 수 있습니다. 화면에 보이기 전에 가립니다.
enum InstallationDiagnostics {
    static func sanitized(_ output: String, environment: [String: String] = [:]) -> String {
        var value = output
        for (key, secret) in environment where ["TOKEN", "PASSWORD", "SECRET", "API_KEY", "AUTH"].contains(where: key.uppercased().contains) && !secret.isEmpty {
            value = value.replacingOccurrences(of: secret, with: "[인증 정보 생략]")
        }
        for (pattern, replacement) in [
            (#"\u001B\[[0-?]*[ -/]*[@-~]"#, ""),
            (#"(?is)-----BEGIN .*?-----.*?-----END .*?-----"#, "[인증서 내용 생략]"),
            (#"(?i)\b(?:https?|socks5?|file)://[^\s<>\"']+"#, "[주소 생략]"),
            (#"(?im)^.*(?:authorization|bearer\s|password\s*[:=]|token\s*[:=]|api[_-]?key\s*[:=]).*$"#, "[인증 정보가 포함된 줄 생략]")
        ] {
            value = value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        value = value.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        return String(value.suffix(6000)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func failure(step: String, status: Int32, output: String, environment: [String: String]) -> AppFailure {
        let lower = output.lowercased()
        let advice: String
        if ["certificate", "unknownissuer", "unknown issuer", "ssl", "tls"].contains(where: lower.contains) {
            advice = "인증서 검증에 실패했습니다. 회사 네트워크에서 macOS 인증서 사용을 켜거나, 사내 루트 인증서를 포함한 PEM 묶음을 지정하세요."
        } else if lower.contains("407") || lower.contains("proxy authentication") {
            advice = "프록시 인증이 필요합니다. 회사 프록시 주소와 인증 설정을 확인하세요."
        } else if lower.contains("403") || lower.contains("forbidden") {
            advice = "다운로드 요청이 거절되었습니다. 사내 허용 주소·미러·저장소 접근 권한을 확인하세요."
        } else if ["timeout", "timed out", "dns", "connect", "resolve"].contains(where: lower.contains) {
            advice = "다운로드 서버에 연결하지 못했습니다. 프록시·DNS·네트워크 허용 정책을 확인하세요."
        } else if lower.contains("no space") {
            advice = "디스크 여유 공간을 확보한 뒤 다시 시도하세요."
        } else {
            advice = "아래 진단 내용을 확인하세요. 기존 Python·venv 선택, 패키지 저장소 또는 오프라인 파일로 다시 준비할 수 있습니다."
        }
        let detail = sanitized(output, environment: environment)
        return AppFailure(message: "\(step)에 실패했습니다(종료 코드 \(status)).\n\(advice)" + (detail.isEmpty ? "" : "\n\n진단 내용\n\(detail)"))
    }
}
