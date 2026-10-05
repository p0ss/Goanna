// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_speech_input.h"

#include <algorithm>
#include <chrono>
#include <vector>

#include <godot_cpp/core/class_db.hpp>

#include "whisper.h"

#if defined(_MSC_VER) && (defined(_M_X64) || defined(_M_IX86))
#include <immintrin.h>
#include <intrin.h>
#elif defined(__x86_64__) || defined(__i386__)
#include <cpuid.h>
#endif

using namespace godot;

namespace goanna {

// ggml is built for AVX2 with FMA and F16C (CMakeLists.txt), so on an older
// processor (an i5-2500K, say, which a tester plays on) the first
// transcription would end the game with an illegal instruction. Asked of the
// processor itself, once, before whisper.cpp runs anything.
static bool cpu_has_whisper_isa() {
#if defined(_MSC_VER) && (defined(_M_X64) || defined(_M_IX86))
    int r[4];
    __cpuid(r, 1);
    const bool fma = r[2] & (1 << 12), osxsave = r[2] & (1 << 27), avx = r[2] & (1 << 28),
               f16c = r[2] & (1 << 29);
    if (!(fma && osxsave && avx && f16c) || (_xgetbv(0) & 6) != 6)
        return false;
    __cpuidex(r, 7, 0);
    return r[1] & (1 << 5);
#elif defined(__x86_64__) || defined(__i386__)
    unsigned a, b, c, d;
    if (!__get_cpuid(1, &a, &b, &c, &d))
        return false;
    const bool fma = c & (1u << 12), osxsave = c & (1u << 27), avx = c & (1u << 28),
               f16c = c & (1u << 29);
    if (!(fma && osxsave && avx && f16c))
        return false;
    // The operating system must save the AVX registers, or using them faults.
    unsigned lo, hi;
    __asm__ volatile("xgetbv" : "=a"(lo), "=d"(hi) : "c"(0));
    if ((lo & 6) != 6)
        return false;
    if (!__get_cpuid_count(7, 0, &a, &b, &c, &d))
        return false;
    return b & (1u << 5);
#else
    return true;
#endif
}

bool GoannaSpeechInput::cpu_supported() {
    static const bool ok = cpu_has_whisper_isa();
    return ok;
}

// whisper.cpp logs every load and every decode to stderr; Goanna's log is
// for Goanna. Failures still reach GDScript through the result.
static void quiet_log(enum ggml_log_level, const char *, void *) {}

GoannaSpeechInput::GoannaSpeechInput() {}

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
    if (m_busy || !cpu_supported())
        return false;
    join();
    m_busy = true;
    {
        std::lock_guard<std::mutex> lk(m_mutex);
        m_state = "loading";
    }
    const std::string file = path.utf8().get_data();
    // Here rather than in the constructor, so nothing of whisper.cpp runs
    // on a processor cpu_supported() turned away.
    whisper_log_set(quiet_log, nullptr);
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
    if (m_busy || !m_ctx || samples.is_empty() || !cpu_supported())
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
    ClassDB::bind_static_method("GoannaSpeechInput", D_METHOD("cpu_supported"),
            &GoannaSpeechInput::cpu_supported);
}

} // namespace goanna
