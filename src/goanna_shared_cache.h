// SPDX-License-Identifier: LGPL-2.1-or-later
// Bounded immutable results shared only by callers with matching inputs.
#pragma once
#include <condition_variable>
#include <exception>
#include <functional>
#include <list>
#include <map>
#include <memory>
#include <mutex>
#include <string>

namespace goanna {
template <typename T> class SharedCache {
public:
    using Value = std::shared_ptr<const T>;
    explicit SharedCache(size_t budget) : m_budget(budget) {}
    Value find(const std::string &key) {
        std::lock_guard<std::mutex> lock(m_mutex);
        auto it = m_values.find(key);
        if (it == m_values.end()) return {};
        m_order.splice(m_order.end(), m_order, it->second.order);
        return it->second.value;
    }
    void put(const std::string &key, Value value, size_t bytes) {
        if (!value || bytes + key.size() > m_budget) return;
        std::lock_guard<std::mutex> lock(m_mutex);
        if (m_values.count(key)) return;
        bytes += key.size();
        while (!m_order.empty() && m_bytes + bytes > m_budget) {
            auto it = m_values.find(m_order.front());
            m_bytes -= it->second.bytes;
            m_values.erase(it);
            m_order.pop_front();
        }
        m_order.push_back(key);
        m_values.emplace(key, Entry{std::move(value), bytes, std::prev(m_order.end())});
        m_bytes += bytes;
    }
    // One builder per exact input. Waiters hold no map/session/Godot locks.
    // Exceptions wake every waiter; an unsuccessful build is not cached.
    Value get(const std::string &key, const std::function<Value()> &build,
            const std::function<size_t(const T &)> &size, bool &reused) {
        std::shared_ptr<Flight> flight;
        {
            std::unique_lock<std::mutex> lock(m_mutex);
            auto ready = m_values.find(key);
            if (ready != m_values.end()) {
                m_order.splice(m_order.end(), m_order, ready->second.order);
                reused = true;
                return ready->second.value;
            }
            auto pending = m_flights.find(key);
            if (pending != m_flights.end()) {
                flight = pending->second;
                flight->wake.wait(lock, [&] { return flight->done; });
                if (flight->error) std::rethrow_exception(flight->error);
                reused = true;
                return flight->value;
            }
            flight = std::make_shared<Flight>();
            m_flights.emplace(key, flight);
        }
        Value value;
        std::exception_ptr error;
        try { value = build(); if (value) put(key, value, size(*value)); }
        catch (...) { error = std::current_exception(); }
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            flight->value = value; flight->error = error; flight->done = true;
            m_flights.erase(key);
        }
        flight->wake.notify_all();
        reused = false;
        if (error) std::rethrow_exception(error);
        return value;
    }
private:
    struct Entry { Value value; size_t bytes; std::list<std::string>::iterator order; };
    struct Flight { Value value; std::exception_ptr error; bool done = false; std::condition_variable wake; };
    std::mutex m_mutex;
    size_t m_budget, m_bytes = 0;
    std::list<std::string> m_order;
    std::map<std::string, Entry> m_values;
    std::map<std::string, std::shared_ptr<Flight>> m_flights;
};
} // namespace goanna
