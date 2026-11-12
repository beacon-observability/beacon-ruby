# frozen_string_literal: true

require 'mkmf'
abort 'Beacon native profiling requires CRuby 3.3+' unless RUBY_ENGINE == 'ruby' && Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.3')
abort 'Missing Ruby profiling API' unless have_func('rb_profile_frames', 'ruby/debug.h')
abort 'Missing Ruby postponed jobs API' unless have_func('rb_postponed_job_preregister', 'ruby/debug.h')
abort 'Missing Ruby thread events API' unless have_func('rb_internal_thread_add_event_hook', 'ruby/thread.h')
abort 'Missing Ruby thread storage API' unless have_func('rb_internal_thread_specific_key_create', 'ruby/thread.h')
append_cflags %w[-std=c11 -Wall -Wextra]
create_makefile('beacon/profiling/native_ext')
