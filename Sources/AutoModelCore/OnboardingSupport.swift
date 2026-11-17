import Foundation

public enum OnboardingValidationError: Error, Equatable, LocalizedError, Sendable {
    case noHealthyModel
    case proxyUnavailable(String)
    case httpFailure(Int, String)
    case missingReceipt

    public var errorDescription: String? {
        switch self {
        case .noHealthyModel:
            return "没有可验收的健康模型。请前往「供应商」手动添加并测活，或明确启动本地模拟上游后再试。"
        case .proxyUnavailable(let detail):
            return "本地代理未能启动：\(detail)。请检查 127.0.0.1 端口是否被占用，在设置中更换端口后重试。"
        case .httpFailure(let status, let message):
            if status == 401 || status == 403 {
                return "本地验收认证失败 (HTTP \(status))。请重新复制 token 或重新一键接入 Agent；不要改用旧占位 key。"
            }
            if status == 429 {
                return "验收请求被额度或预算限制 (HTTP 429)：\(message)。请检查供应商额度与 AutoRoute 月度预算。"
            }
            return "真实 HTTP 验收失败 (HTTP \(status))：\(message)。请检查供应商 Base URL、API Key、模型 ID、额度与网络后重试。"
        case .missingReceipt:
            return "HTTP 请求已结束但没有生成路由收据。请查看首页错误记录，并确认请求确实经过本机代理。"
        }
    }
}

public struct OnboardingValidationResult: Sendable {
    public var isDemo: Bool
    public var record: CallRecord

    public init(isDemo: Bool, record: CallRecord) {
        self.isDemo = isDemo
        self.record = record
    }
}

@MainActor
public extension AutoModelEngine {
    func validateOnboardingEndToEnd() async throws -> OnboardingValidationResult {
        guard config.models.contains(where: {
            $0.isEnabled && !$0.isAutoEvicted && $0.availabilityStatus == .available
        }) else {
            throw OnboardingValidationError.noHealthyModel
        }

        if !proxyState.isRunning {
            startProxy()
        }
        guard proxyState.isRunning else {
            throw OnboardingValidationError.proxyUnavailable(proxyState.statusText)
        }

        let existingIDs = Set(callHistory.map(\.id))
        var request = URLRequest(url: URL(string: "\(config.proxySettings.baseURLString)/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(localAPIToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "auto",
            "stream": false,
            "messages": [[
                "role": "user",
                "content": "请只回复：AutoRoute 本地路由验收成功"
            ]]
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw OnboardingValidationError.proxyUnavailable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OnboardingValidationError.missingReceipt
        }
        guard (200..<300).contains(http.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = ((object?["error"] as? [String: Any])?["message"] as? String)
                ?? String(data: data, encoding: .utf8)
                ?? "未知错误"
            throw OnboardingValidationError.httpFailure(http.statusCode, message)
        }
        guard let record = callHistory.first(where: { !existingIDs.contains($0.id) }) else {
            throw OnboardingValidationError.missingReceipt
        }
        let isDemo = record.executionOrigin == .demo
        if isDemo {
            recordOnboardingDemoValidation()
        } else if record.executionOrigin == .real {
            setOnboardingCompleted(true)
        }
        return OnboardingValidationResult(isDemo: isDemo, record: record)
    }

    func skipOnboarding() {
        recordOnboardingSkipped()
        setOnboardingCompleted(true)
    }
}
