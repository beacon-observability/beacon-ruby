/* Beacon native heap/GVL recorder.
 * Heap pending-recording / weak-map design adapted from dd-trace-rb 2.48.0.
 * Copyright 2016-Present Datadog, Inc.; modifications Copyright 2026 Beacon Authors.
 * SPDX-License-Identifier: BSD-3-Clause
 * See licenses/ for upstream license, notice and provenance.
 */
/* cspell:words Qfalse Qnil RARRAY RTEST SIZET */
#include <ruby.h>
#include <ruby/debug.h>
#include <ruby/ractor.h>
#include <ruby/thread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include "gvl_tls.h"

#define MAX_PENDING 256
#define MAX_THREADS 1024

typedef struct {
    VALUE object_ref; /* Strong only until deferred insertion in the weak map. */
    VALUE *frames;
    int *lines, length;
    bool used, pending;
} heap_record;

typedef struct {
    VALUE thread, *frames;
    int *lines, length;
    uint64_t wait_ns, end_epoch_ns;
} gvl_record;

struct beacon_thread_context {
    _Atomic VALUE thread;
    _Atomic uint64_t generation;
    _Atomic uint64_t ready_ns;
};

typedef struct {
    VALUE weak_objects, tracepoint;
    heap_record *heap;
    gvl_record *gvl;
    VALUE *heap_frames, *gvl_frames;
    int *heap_lines, *gvl_lines;
    size_t *free_slots, free_count, capacity, depth, pending_count, gvl_count, thread_count, max_threads;
    uint64_t interval, seen, heap_dropped, gvl_dropped, gvl_wait_total, last_prune;
    _Atomic uint64_t generation, started_ns;
    bool heap_enabled, size_enabled, gvl_enabled, busy;
    _Atomic bool running;
    _Atomic pid_t pid;
    rb_internal_thread_event_hook_t *hook;
} recorder;

/* Stable storage: READY callbacks run without the GVL and may outlive hook removal. */
static struct beacon_thread_context thread_slots[MAX_THREADS];
static recorder state;
static VALUE instance = Qnil, object_space;
static rb_postponed_job_handle_t commit_handle;
static rb_ractor_local_key_t owner_key;
static ID id_keys, id_get, id_set, id_memsize;

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static bool owner_ractor(void) {
    VALUE owner;
    return rb_ractor_local_storage_value_lookup(owner_key, &owner) && owner == instance;
}

static void mark(void *ptr) {
    recorder *s = ptr;
    rb_gc_mark(s->weak_objects);
    rb_gc_mark(s->tracepoint);
    for (size_t i = 0; i < s->capacity; i++) {
        heap_record *r = &s->heap[i];
        if (!r->used) continue;
        if (r->pending) rb_gc_mark(r->object_ref);
        for (int j = 0; j < r->length; j++) rb_gc_mark(r->frames[j]);
    }
    for (size_t i = 0; i < s->gvl_count; i++) {
        rb_gc_mark(s->gvl[i].thread);
        for (int j = 0; j < s->gvl[i].length; j++) rb_gc_mark(s->gvl[i].frames[j]);
    }
    for (size_t i = 0; i < s->thread_count; i++) rb_gc_mark(thread_slots[i].thread);
}

static size_t memory_size(const void *ptr) {
    const recorder *s = ptr;
    return sizeof(*s) + s->capacity * (sizeof(heap_record) + sizeof(gvl_record) + sizeof(size_t)
        + 2 * s->depth * (sizeof(VALUE) + sizeof(int)));
}

static const rb_data_type_t recorder_type = {
    .wrap_struct_name = "Beacon::Profiling::NativeRecorder",
    .function = {.dmark = mark, .dsize = memory_size},
    .flags = 0 /* Unprotected typed data: every minor GC must scan newly captured references. */
};

static VALUE commit_pending(VALUE unused) {
    (void)unused;
    for (size_t i = 0; i < state.capacity; i++) {
        heap_record *r = &state.heap[i];
        if (!r->used || !r->pending) continue;
        rb_funcall(state.weak_objects, id_set, 2, r->object_ref, SIZET2NUM(i));
        r->object_ref = Qnil;
        r->pending = false;
        state.pending_count--;
    }
    /* Reclaim dead slots at most once a second when the bounded table is full. */
    uint64_t now = now_ns();
    if (state.free_count == 0 && now - state.last_prune >= 1000000000ULL) {
        bool *alive = calloc(state.capacity, sizeof(bool));
        if (!alive) return Qnil;
        VALUE keys = rb_funcall(state.weak_objects, id_keys, 0);
        for (long i = 0; i < RARRAY_LEN(keys); i++) {
            size_t index = NUM2SIZET(rb_funcall(state.weak_objects, id_get, 1, rb_ary_entry(keys, i)));
            if (index < state.capacity) alive[index] = true;
        }
        for (size_t i = 0; i < state.capacity; i++) {
            if (state.heap[i].used && !alive[i] && !state.heap[i].pending) {
                state.heap[i].used = false;
                state.heap[i].length = 0;
                state.free_slots[state.free_count++] = i;
            }
        }
        free(alive);
        state.last_prune = now;
        RB_GC_GUARD(keys);
    }
    return Qnil;
}

static void deferred_commit(void *unused) {
    (void)unused;
    if (state.pid != getpid() || state.busy || !owner_ractor()) return;
    VALUE saved_error = rb_errinfo();
    int error = 0;
    state.busy = true;
    rb_protect(commit_pending, Qnil, &error);
    if (error) {
        state.heap_enabled = false;
        for (size_t i = 0; i < state.capacity; i++) {
            if (state.heap[i].pending) {
                state.heap[i].pending = false;
                state.heap[i].object_ref = Qnil;
                state.heap[i].used = false;
            }
        }
        state.pending_count = 0;
    }
    state.busy = false;
    rb_set_errinfo(saved_error);
}

static void on_allocation(VALUE tp, void *unused) {
    (void)unused;
    if (!state.running || state.pid != getpid() || !owner_ractor()) return;
    if (!state.heap_enabled || state.busy) return;
    if (++state.seen % state.interval) return;
    if (!state.free_count || state.pending_count >= MAX_PENDING) {
        state.heap_dropped++;
        if (state.pending_count || now_ns() - state.last_prune >= 1000000000ULL)
            rb_postponed_job_trigger(commit_handle);
        return;
    }
    size_t index = state.free_slots[--state.free_count];
    heap_record *r = &state.heap[index];
    r->used = r->pending = true;
    r->object_ref = rb_tracearg_object(rb_tracearg_from_tracepoint(tp));
    r->length = rb_profile_frames(0, (int)state.depth, r->frames, r->lines);
    state.pending_count++;
    rb_postponed_job_trigger(commit_handle);
}

static void on_thread_event(rb_event_flag_t event, const rb_internal_thread_event_data_t *data, void *unused) {
    (void)unused;
    if (!state.running || state.pid != getpid()) return;
    per_thread_context *ctx = beacon_get_thread_context(data->thread);
    if (event == RUBY_INTERNAL_THREAD_EVENT_EXITED) {
        if (ctx && ctx->generation == state.generation) {
            VALUE expected = data->thread;
            atomic_compare_exchange_strong(&ctx->thread, &expected, Qnil);
        }
        return;
    }
    if (event == RUBY_INTERNAL_THREAD_EVENT_READY) {
        if (ctx && ctx->generation == state.generation && ctx->thread == data->thread)
            atomic_store_explicit(&ctx->ready_ns, now_ns(), memory_order_release);
        return;
    }
    /* RESUMED has the GVL. Other Ractor contexts are deliberately excluded. */
    if (!owner_ractor()) return;
    if (!ctx || ctx->generation != state.generation || ctx->thread != data->thread) {
        size_t index = 0;
        while (index < state.thread_count && thread_slots[index].thread != Qnil) index++;
        if (index == state.thread_count) {
            if (state.thread_count >= state.max_threads) { state.gvl_dropped++; return; }
            state.thread_count++;
        }
        ctx = &thread_slots[index];
        ctx->thread = data->thread;
        ctx->generation = state.generation;
        atomic_store(&ctx->ready_ns, 0);
        beacon_set_thread_context(data->thread, ctx);
        return;
    }
    uint64_t ready = atomic_exchange_explicit(&ctx->ready_ns, 0, memory_order_acquire);
    if (!ready || ready < state.started_ns) return;
    uint64_t wait = now_ns() - ready;
    state.gvl_wait_total += wait;
    if (state.busy || wait < 1000000ULL) return;
    if (state.gvl_count >= state.capacity) { state.gvl_dropped++; return; }
    gvl_record *r = &state.gvl[state.gvl_count++];
    r->thread = data->thread;
    r->wait_ns = wait;
    struct timespec epoch;
    clock_gettime(CLOCK_REALTIME, &epoch);
    r->end_epoch_ns = (uint64_t)epoch.tv_sec * 1000000000ULL + (uint64_t)epoch.tv_nsec;
    r->length = rb_thread_current() == data->thread ? rb_profile_frames(0, (int)state.depth, r->frames, r->lines) : 0;
}

static void release_buffers(void) {
    free(state.heap); free(state.gvl); free(state.heap_frames); free(state.gvl_frames);
    free(state.heap_lines); free(state.gvl_lines); free(state.free_slots);
    state.heap = NULL; state.gvl = NULL; state.heap_frames = NULL; state.gvl_frames = NULL;
    state.heap_lines = NULL; state.gvl_lines = NULL; state.free_slots = NULL; state.capacity = 0;
}

static VALUE create(VALUE klass, VALUE interval, VALUE capacity, VALUE depth, VALUE threads, VALUE heap, VALUE size, VALUE gvl) {
    if (state.running) rb_raise(rb_eRuntimeError, "Beacon native recorder already active");
    size_t cap = NUM2SIZET(capacity), frames = NUM2SIZET(depth), thread_count = NUM2SIZET(threads);
    uint64_t stride = NUM2ULL(interval);
    if (!stride || cap < 1 || cap > 10000 || frames < 1 || frames > 512 || thread_count < 1 || thread_count > MAX_THREADS)
        rb_raise(rb_eArgError, "Invalid native recorder limits");
    if (NIL_P(instance)) instance = TypedData_Wrap_Struct(klass, &recorder_type, &state);
    rb_ractor_local_storage_value_set(owner_key, instance);
    state.busy = true;
    release_buffers();
    state.heap = calloc(cap, sizeof(heap_record));
    state.gvl = calloc(cap, sizeof(gvl_record));
    state.heap_frames = calloc(cap * frames, sizeof(VALUE));
    state.gvl_frames = calloc(cap * frames, sizeof(VALUE));
    state.heap_lines = calloc(cap * frames, sizeof(int));
    state.gvl_lines = calloc(cap * frames, sizeof(int));
    state.free_slots = calloc(cap, sizeof(size_t));
    if (!state.heap || !state.gvl || !state.heap_frames || !state.gvl_frames || !state.heap_lines || !state.gvl_lines || !state.free_slots) {
        release_buffers(); state.busy = false; rb_memerror();
    }
    state.capacity = state.free_count = cap;
    state.depth = frames; state.interval = stride; state.max_threads = thread_count;
    state.pending_count = state.gvl_count = state.thread_count = 0;
    state.heap_dropped = state.gvl_dropped = state.gvl_wait_total = state.seen = 0;
    state.heap_enabled = RTEST(heap); state.size_enabled = RTEST(size); state.gvl_enabled = RTEST(gvl);
    state.generation++; state.pid = getpid(); state.last_prune = now_ns();
    for (size_t i = 0; i < cap; i++) {
        state.free_slots[i] = cap - i - 1;
        state.heap[i].frames = state.heap_frames + i * frames;
        state.heap[i].lines = state.heap_lines + i * frames;
        state.gvl[i].frames = state.gvl_frames + i * frames;
        state.gvl[i].lines = state.gvl_lines + i * frames;
    }
    VALUE weak_class = rb_const_get(object_space, rb_intern("WeakMap"));
    state.weak_objects = rb_class_new_instance(0, NULL, weak_class);
    if (NIL_P(state.tracepoint)) state.tracepoint = rb_tracepoint_new(Qnil, RUBY_INTERNAL_EVENT_NEWOBJ, on_allocation, NULL);
    state.busy = false;
    return instance;
}

static VALUE start(VALUE self) {
    if (state.running) return Qfalse;
    if (!state.capacity) rb_raise(rb_eRuntimeError, "Native recorder is not configured");
    state.pid = getpid(); state.started_ns = now_ns(); state.running = true;
    if (state.gvl_enabled) state.hook = rb_internal_thread_add_event_hook(on_thread_event,
        RUBY_INTERNAL_THREAD_EVENT_READY | RUBY_INTERNAL_THREAD_EVENT_RESUMED | RUBY_INTERNAL_THREAD_EVENT_EXITED, NULL);
    if (state.heap_enabled) rb_tracepoint_enable(state.tracepoint);
    return self;
}

static VALUE stop(VALUE self) {
    state.running = false;
    if (!NIL_P(state.tracepoint)) rb_tracepoint_disable(state.tracepoint);
    if (state.hook) { rb_internal_thread_remove_event_hook(state.hook); state.hook = NULL; }
    deferred_commit(NULL);
    state.thread_count = 0;
    return self;
}

static VALUE symbol(const char *value) { return ID2SYM(rb_intern(value)); }
static void put(VALUE hash, const char *key, VALUE value) { rb_hash_aset(hash, symbol(key), value); }

static VALUE profile(const char *mode, VALUE frames, VALUE raw, VALUE labels) {
    VALUE result = rb_hash_new();
    put(result, "mode", symbol(mode)); put(result, "interval", INT2FIX(1));
    put(result, "frames", frames); put(result, "raw", raw); put(result, "labels", labels);
    put(result, "samples", LONG2NUM(RARRAY_LEN(raw) ? 1 : 0));
    return result;
}

static void add_stack(VALUE frames, VALUE raw, VALUE *stack, int *lines, int length, uint64_t weight) {
    rb_ary_push(raw, INT2NUM(length));
    /* rb_profile_frames gives leaves first; Beacon's intermediate form is roots first. */
    for (int j = length - 1; j >= 0; j--) {
        VALUE info = rb_hash_new(), id = LONG2NUM(RHASH_SIZE(frames) + 1);
        VALUE label = rb_profile_frame_full_label(stack[j]);
        VALUE file = rb_profile_frame_absolute_path(stack[j]);
        put(info, "name", NIL_P(label) ? rb_str_new_cstr("[native]") : label);
        put(info, "file", NIL_P(file) ? rb_str_new_cstr("") : file);
        put(info, "line", INT2NUM(lines[j] > 0 ? lines[j] : 0));
        rb_hash_aset(frames, id, info); rb_ary_push(raw, id);
    }
    rb_ary_push(raw, ULL2NUM(weight));
}

static VALUE build_snapshot(VALUE unused) {
    (void)unused;
    commit_pending(Qnil);
    VALUE objects_frames = rb_hash_new(), objects_raw = rb_ary_new();
    VALUE bytes_frames = rb_hash_new(), bytes_raw = rb_ary_new();
    VALUE gvl_frames = rb_hash_new(), gvl_raw = rb_ary_new(), labels = rb_hash_new();
    VALUE keys = rb_funcall(state.weak_objects, id_keys, 0);
    for (long i = 0; i < RARRAY_LEN(keys); i++) {
        VALUE object = rb_ary_entry(keys, i);
        size_t index = NUM2SIZET(rb_funcall(state.weak_objects, id_get, 1, object));
        if (index >= state.capacity || !state.heap[index].used) continue;
        heap_record *r = &state.heap[index];
        add_stack(objects_frames, objects_raw, r->frames, r->lines, r->length, state.interval);
        if (state.size_enabled) {
            uint64_t size = NUM2ULL(rb_funcall(object_space, id_memsize, 1, object));
            if (size <= INT64_MAX / state.interval)
                add_stack(bytes_frames, bytes_raw, r->frames, r->lines, r->length, size * state.interval);
        }
    }
    for (size_t i = 0; i < state.gvl_count; i++) {
        gvl_record *r = &state.gvl[i];
        VALUE label = rb_hash_new();
        rb_hash_aset(label, rb_str_new_cstr("thread id"), rb_obj_as_string(rb_obj_id(r->thread)));
        rb_hash_aset(label, rb_str_new_cstr("state"), rb_str_new_cstr("waiting for gvl"));
        rb_hash_aset(label, rb_str_new_cstr("end_timestamp_ns"), ULL2NUM(r->end_epoch_ns));
        rb_hash_aset(labels, LONG2NUM(RARRAY_LEN(gvl_raw)), label);
        add_stack(gvl_frames, gvl_raw, r->frames, r->lines, r->length, r->wait_ns);
    }
    state.gvl_count = 0;
    VALUE result = rb_ary_new();
    rb_ary_push(result, profile("heap_objects", objects_frames, objects_raw, rb_hash_new()));
    if (state.size_enabled) rb_ary_push(result, profile("heap_size", bytes_frames, bytes_raw, rb_hash_new()));
    if (state.gvl_enabled) {
        rb_ary_push(result, profile("gvl_wait", gvl_frames, gvl_raw, labels));
        rb_ary_push(result, profile("timeline", gvl_frames, gvl_raw, labels));
    }
    if (!state.running) {
        for (size_t i = 0; i < state.capacity; i++) {
            state.heap[i].used = false;
            state.heap[i].length = 0;
        }
        state.weak_objects = rb_class_new_instance(0, NULL, rb_const_get(object_space, rb_intern("WeakMap")));
    }
    RB_GC_GUARD(keys);
    return result;
}

static VALUE clear_busy(VALUE unused) { (void)unused; state.busy = false; return Qnil; }
static VALUE snapshot(VALUE self) {
    (void)self;
    state.busy = true;
    return rb_ensure(build_snapshot, Qnil, clear_busy, Qnil);
}

static VALUE stats(VALUE self) {
    (void)self;
    VALUE result = rb_hash_new();
    put(result, "gvl_waiting_time_ns_total", ULL2NUM(state.gvl_wait_total));
    put(result, "heap_samples_dropped", ULL2NUM(state.heap_dropped));
    put(result, "gvl_samples_dropped", ULL2NUM(state.gvl_dropped));
    put(result, "heap_samples_observed", ULL2NUM(state.seen / state.interval));
    return result;
}

static VALUE after_fork(VALUE self) {
    stop(self); state.pid = getpid(); state.thread_count = 0;
    return self;
}

static VALUE clock_pair(VALUE klass) {
    (void)klass;
    struct timespec epoch;
    if (clock_gettime(CLOCK_REALTIME, &epoch) != 0) rb_sys_fail("clock_gettime");
    uint64_t realtime = (uint64_t)epoch.tv_sec * 1000000000ULL + (uint64_t)epoch.tv_nsec;
    uint64_t monotonic = now_ns();
    return rb_ary_new_from_args(2, ULL2NUM(realtime), ULL2NUM(monotonic));
}

void Init_native_ext(void) {
    VALUE beacon = rb_define_module("Beacon"), profiling = rb_define_module_under(beacon, "Profiling");
    VALUE klass = rb_define_class_under(profiling, "NativeRecorder", rb_cObject);
    rb_undef_alloc_func(klass);
    state.weak_objects = state.tracepoint = Qnil;
    object_space = rb_const_get(rb_cObject, rb_intern("ObjectSpace"));
    rb_global_variable(&instance); rb_global_variable(&object_space);
    id_keys = rb_intern("keys"); id_get = rb_intern("[]"); id_set = rb_intern("[]="); id_memsize = rb_intern("memsize_of");
    owner_key = rb_ractor_local_storage_value_newkey();
    beacon_thread_context_tls_init();
    commit_handle = rb_postponed_job_preregister(0, deferred_commit, NULL);
    if (commit_handle == POSTPONED_JOB_HANDLE_INVALID) rb_raise(rb_eRuntimeError, "No native postponed job slots available");
    rb_define_singleton_method(klass, "create", create, 7);
    rb_define_singleton_method(klass, "clock_pair", clock_pair, 0);
    rb_define_method(klass, "start", start, 0); rb_define_method(klass, "stop", stop, 0);
    rb_define_method(klass, "snapshot", snapshot, 0); rb_define_method(klass, "stats", stats, 0);
    rb_define_method(klass, "discard_after_fork", after_fork, 0);
}
