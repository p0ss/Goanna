// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// Speech to text for voice typing (project/ui/voice_input.gd): a Whisper
// model, through whisper.cpp, turning a few seconds of the player's voice
// into a line of chat. Everything happens on this computer. The audio is
// handed in as samples, transcribed and dropped; nothing is written to disk
// or sent anywhere.
//
// Loading a model and transcribing both take long enough to stall a frame,
// so each runs on a thread of its own and GDScript polls for the result.
// One job at a time: a request while one is running is refused.
#pragma once

#include <atomic>
#include <mutex>
#include <string>
#include <thread>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/string.hpp>

struct whisper_context;

namespace goanna {

class GoannaSpeechInput : public godot::RefCounted {
    GDCLASS(GoannaSpeechInput, godot::RefCounted)

public:
    GoannaSpeechInput();
    ~GoannaSpeechInput() override;

    // Starts loading a ggml Whisper model from a file. False if a job is
    // already running. state() says when it is ready, or why it failed.
    bool load_model(const godot::String &path);
    // Starts transcribing mono samples at 16 kHz, -1 to 1. language is a
    // Whisper language code ("en", "es") or "auto"; prompt is text the
    // speech is likely to contain (player names, recent chat), which helps
    // the model spell them. False if no model is loaded or a job is running.
    bool transcribe(const godot::PackedFloat32Array &samples, const godot::String &language,
            const godot::String &prompt);
    // "empty", "loading", "ready", "transcribing" or "failed".
    godot::String state() const;
    bool busy() const { return m_busy; }
    // The finished transcription, once: {text, language, ms}, or {} while
    // there is none. A failed load or transcription gives {error}.
    godot::Dictionary take_result();
    // Threads a transcription uses; by default half the cores, at most four.
    void set_threads(int threads) { m_threads = threads; }

protected:
    static void _bind_methods();

private:
    void join();

    whisper_context *m_ctx = nullptr;
    std::thread m_worker;
    std::atomic<bool> m_busy{false};
    mutable std::mutex m_mutex;
    std::string m_state = "empty";
    godot::Dictionary m_result;
    bool m_has_result = false;
    int m_threads = 0;
};

} // namespace goanna
