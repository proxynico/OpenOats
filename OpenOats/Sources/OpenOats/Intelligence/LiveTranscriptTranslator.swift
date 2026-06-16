import Foundation
import NaturalLanguage

/// Translates non-English/Spanish utterances into English so the listener can
/// follow a foreign-language counterpart in real time.
///
/// Calls Ollama's NATIVE `/api/chat` endpoint with thinking disabled: the
/// OpenAI-compatible `/v1/chat/completions` endpoint returns empty content for
/// thinking models (e.g. qwen3.5), so `LiveTranscriptCleaner`'s client cannot
/// be reused here. Runs as a background actor with bounded concurrency,
/// mirroring `LiveTranscriptCleaner`, and writes the result back into the
/// stored utterance's `translatedText`.
actor LiveTranscriptTranslator {
    private let settings: AppSettings
    private let transcriptStore: TranscriptStore

    private let maxConcurrent = 3
    private var inFlightCount = 0
    private var pendingQueue: [Utterance] = []
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    private let minimumWordCount = 2

    /// Languages the user reads natively — left untranslated.
    private let passthroughLanguages: Set<String> = ["en", "es"]

    private let systemPrompt = """
        You are a translation engine for a live business call. Translate the \
        user's message into natural English, preserving names, numbers, and \
        currency amounts exactly. Output ONLY the English translation — no \
        notes, no quotes, no original text, no explanation.
        """

    init(settings: AppSettings, transcriptStore: TranscriptStore) {
        self.settings = settings
        self.transcriptStore = transcriptStore
    }

    /// Queue an utterance for translation. No-op (marked skipped) when the text
    /// is too short or already in a language the user reads.
    func translate(_ utterance: Utterance) {
        let text = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.split(separator: " ").count < minimumWordCount {
            markSkipped(utterance.id)
            return
        }
        if let lang = detectLanguage(text), passthroughLanguages.contains(lang) {
            markSkipped(utterance.id)
            return
        }

        pendingQueue.append(utterance)
        drainQueue()
    }

    /// Await all pending and in-flight translations, with a timeout.
    func drain(timeout: Duration = .seconds(8)) async {
        guard inFlightCount > 0 || !pendingQueue.isEmpty else { return }

        let tasks = activeTasks.values.map { $0 }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for task in tasks { await task.value }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Private

    /// Returns the dominant language as a 2-letter subtag (e.g. "zh-Hans" -> "zh"),
    /// or nil if undetermined.
    private func detectLanguage(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let lang = recognizer.dominantLanguage else { return nil }
        return String(lang.rawValue.prefix(2))
    }

    private func drainQueue() {
        while inFlightCount < maxConcurrent, let utterance = pendingQueue.first {
            pendingQueue.removeFirst()
            inFlightCount += 1

            let store = transcriptStore
            Task { @MainActor in
                store.updateTranslation(id: utterance.id, translatedText: nil, status: .pending)
            }

            let task = Task { [weak self] in
                guard let self else { return }
                await self.performTranslation(utterance)
                await self.taskCompleted(id: utterance.id)
            }
            activeTasks[utterance.id] = task
        }
    }

    private func taskCompleted(id: UUID) {
        activeTasks.removeValue(forKey: id)
        inFlightCount -= 1
        drainQueue()
    }

    private func performTranslation(_ utterance: Utterance) async {
        let baseURL = await MainActor.run { settings.ollamaBaseURL }
        let model = await MainActor.run { settings.translationModel }

        do {
            let english = try await Self.ollamaChat(
                baseURL: baseURL,
                model: model,
                system: systemPrompt,
                user: utterance.text
            )
            let trimmed = english.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                markFailed(utterance.id)
                return
            }
            let store = transcriptStore
            Task { @MainActor in
                store.updateTranslation(id: utterance.id, translatedText: trimmed, status: .completed)
            }
        } catch {
            markFailed(utterance.id)
        }
    }

    private func markSkipped(_ id: UUID) {
        let store = transcriptStore
        Task { @MainActor in
            store.updateTranslation(id: id, translatedText: nil, status: .skipped)
        }
    }

    private func markFailed(_ id: UUID) {
        let store = transcriptStore
        Task { @MainActor in
            store.updateTranslation(id: id, translatedText: nil, status: .failed)
        }
    }

    // MARK: - Native Ollama chat (thinking disabled)

    enum TranslateError: Error { case invalidURL, http(Int, String) }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Msg]
        let think: Bool
        let stream: Bool
        let options: Options
        struct Msg: Encodable { let role: String; let content: String }
        struct Options: Encodable { let temperature: Double; let num_predict: Int }
    }

    private struct ChatResponse: Decodable {
        let message: Msg?
        struct Msg: Decodable { let content: String? }
    }

    private static func ollamaChat(baseURL: String, model: String, system: String, user: String) async throws -> String {
        let normalized = OllamaEmbedClient.normalizeBaseURL(baseURL)
        guard let url = URL(string: normalized + "/api/chat") else { throw TranslateError.invalidURL }

        let body = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: user)
            ],
            think: false,
            stream: false,
            options: .init(temperature: 0, num_predict: 400)
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslateError.http(-1, "No HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw TranslateError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return decoded.message?.content ?? ""
    }
}
