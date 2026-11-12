/* Adapted from dd-trace-rb 2.48.0. Copyright 2016-Present Datadog, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 * Modified for Beacon: use Ruby 3.3+ public thread storage APIs only. */
#include "gvl_tls.h"
  rb_internal_thread_specific_key_t beacon_thread_context_key;

  void beacon_thread_context_tls_init(void) {
    beacon_thread_context_key = rb_internal_thread_specific_key_create();
  }
