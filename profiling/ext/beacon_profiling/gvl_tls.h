/* Adapted from dd-trace-rb 2.48.0. Copyright 2016-Present Datadog, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 * Modified for Beacon: use Ruby 3.3+ public thread storage APIs only. */
#pragma once
#include <ruby.h>
#include <ruby/thread.h>
typedef struct beacon_thread_context per_thread_context;
extern rb_internal_thread_specific_key_t beacon_thread_context_key;
void beacon_thread_context_tls_init(void);
static inline per_thread_context *beacon_get_thread_context(VALUE thread) {
    return rb_internal_thread_specific_get(thread, beacon_thread_context_key);
}
static inline void beacon_set_thread_context(VALUE thread, per_thread_context *value) {
    rb_internal_thread_specific_set(thread, beacon_thread_context_key, value);
}
