#!/bin/sh
# Copyright 2019 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

assert_function_exists() {
  test "$(type $1 | head -n1)" = "$1 is a function" || exit 1
}

# Integration test: Ensure that disk wipe functionality is exposed.
. ${SYSROOT}/usr/sbin/secure-wipe.sh
assert_function_exists secure_erase
assert_function_exists perform_fio_op
