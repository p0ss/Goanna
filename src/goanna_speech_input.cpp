// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_speech_input.h"

#include <algorithm>
#include <chrono>
#include <vector>

#include <godot_cpp/core/class_db.hpp>

#include "whisper.h"

using namespace godot;

namespace goanna {

// whisper.cpp logs every load and every decode to stderr; Goanna's log is
// for Goanna. Failures still reach GDScript through the result.
static void quiet_log(enum ggml_log_level, const char *, void *) {}

GoannaSpeechInput::GoannaSpeechInput() {
    whisper_log_set(quiet_log, nullptr);
}

GoannaSpeechInput::~GoannaSpeechInput() {
    join();
    if (m_ctx)
        whisper_free(m_ctx);
}

void GoannaSpeechInput::join() {
    if (m_worker.joinable())
        m_worker.join();
}

bool GoannaSpeechInput::load_model(const String &path) {
    if (m_busy)
        return false;
    join();
    m_busy = true;
    {
        std::lock_guard<std::mutex> lk(m_mutex);
        m_state = "loading";
    }
    const std::string file = path.utf8().get_data();
    whisper_context *old = m_ctx;
    m_ctx = nullptr;
    m_worker = std::thread([this, file, old]() {
        if (old)
            whisper_free(old);
        whisper_context_params params = whisper_context_default_params();
        params.use_gpu = false;
        whisper_context *ctx = whisper_init_from_file_with_params(file.c_str(), params);
        std::lock_guard<std::mutex> lk(m_mutex);
        m_ctx = ctx;
        m_state = ctx ? "ready" : "failed";
        if (!ctx) {
            m_result = Dictionary();
            m_result["error"] = String("could not load the speech model");
            m_has_result = true;
        }
        m_busy = false;
    });
    return true;
}

bool GoannaSpeechInput::transcribe(const PackedFloat32Array &samples, const String &language,
        const String &prompt) {
    if (m_busy || !m_ctx || samples.is_empty())
        return false;
    join();
    m_busy = true;
    {
        std::lock_guard<std::mutex> lk(m_mutex);
        m_state = "transcribing";
    }
    std::vector<float> audio(samples.ptr(), samples.ptr() + samples.size());
    const std::string lang = language.is_empty() ? "auto" : std::string(language.utf8().get_data());
    const std::string hint = prompt.utf8().get_data();
    int threads = m_threads;
    if (threads <= 0)
        threads = std::clamp((int)std::thread::hardware_concurrency() / 2, 1, 4);
    m_worker = std::thread([this, audio = std::move(audio), lang, hint, threads]() {
        const auto started = std::chrono::steady_clock::now();
        whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
        params.n_threads = threads;
        params.language = lang.c_str();
        params.detect_language = false;
        params.translate = false;
        // One utterance, one line of chat: no timestamps, no carrying text
        // over from an earlier line, and nothing printed.
        params.no_context = true;
        params.no_timestamps = true;
        params.single_segment = true;
        params.print_special = false;
        params.print_progress = false;
        params.print_realtime = false;
        params.print_timestamps = false;
        params.suppress_blank = true;
        params.suppress_nst = true;
        params.initial_prompt = hint.empty() ? nullptr : hint.c_str();
        const int status = whisper_full(m_ctx, params, audio.data(), (int)audio.size());
        std::string text;
        if (status == 0) {
            const int segments = whisper_full_n_segments(m_ctx);
            for (int i = 0; i < segments; ++i)
                text += whisper_full_get_segment_text(m_ctx, i);
        }
        const int lang_id = status == 0 ? whisper_full_lang_id(m_ctx) : -1;
        const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - started).count();
        std::lock_guard<std::mutex> lk(m_mutex);
        m_result = Dictionary();
        if (status != 0) {
            m_result["error"] = String("transcription failed");
        } else {
            m_result["text"] = String::utf8(text.c_str()).strip_edges();
            m_result["language"] = String(lang_id >= 0 ? whisper_lang_str(lang_id) : "");
            m_result["ms"] = (int64_t)ms;
        }
        m_has_result = true;
        m_state = "ready";
        m_busy = false;
    });
    return true;
}

String GoannaSpeechInput::state() const {
    std::lock_guard<std::mutex> lk(m_mutex);
    return String(m_state.c_str());
}

Dictionary GoannaSpeechInput::take_result() {
    std::lock_guard<std::mutex> lk(m_mutex);
    if (!m_has_result)
        return Dictionary();
    m_has_result = false;
    return m_result;
}

void GoannaSpeechInput::_bind_methods() {
    ClassDB::bind_method(D_METHOD("load_model", "path"), &GoannaSpeechInput::load_model);
    ClassDB::bind_method(D_METHOD("transcribe", "samples", "language", "prompt"),
            &GoannaSpeechInput::transcribe);
    ClassDB::bind_method(D_METHOD("state"), &GoannaSpeechInput::state);
    ClassDB::bind_method(D_METHOD("busy"), &GoannaSpeechInput::busy);
    ClassDB::bind_method(D_METHOD("take_result"), &GoannaSpeechInput::take_result);
    ClassDB::bind_method(D_METHOD("set_threads", "threads"), &GoannaSpeechInput::set_threads);
}

} // namespace goanna
