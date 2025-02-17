# =============================================================================
# Copyright (c) 2021, NVIDIA CORPORATION.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except
# in compliance with the License. You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software distributed under the License
# is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
# or implied. See the License for the specific language governing permissions and limitations under
# the License.
# =============================================================================

# This function finds cucollections and sets any additional necessary environment variables.
function(find_and_configure_cucollections)

  # Find or install cuCollections
  rapids_cpm_find(
    # cuCollections doesn't have a version yet
    cuco 0.0
    GLOBAL_TARGETS cuco::cuco
    CPM_ARGS GITHUB_REPOSITORY NVIDIA/cuCollections
    GIT_TAG 6433e8ad7571f14cc5384051b049029c60dd1ce0
    OPTIONS "BUILD_TESTS OFF" "BUILD_BENCHMARKS OFF" "BUILD_EXAMPLES OFF"
  )

endfunction()

find_and_configure_cucollections()
