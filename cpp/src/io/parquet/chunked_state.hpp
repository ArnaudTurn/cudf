/*
 * Copyright (c) 2020, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * @file chunked_state.hpp
 * @brief definition for chunked state structure used by Parquet writer
 */

#pragma once

#include "parquet.h"

namespace cudf {
namespace experimental {
namespace io {
namespace detail {
namespace parquet {

   enum class SingleWriteMode : bool {
      YES,
      NO
   };

   enum class SetMetadata : bool {
      WITH_NULLABILITY,
      WITHOUT_NULLABILITY
   };

   /**
    * @brief Chunked writer state struct. Contains various pieces of information
    *        needed that span the begin() / write() / end() call process.
    */
   struct pq_chunked_state {
      /// The writer to be used
      std::unique_ptr<writer>             wp;  
      /// Cuda stream to be used
      cudaStream_t                        stream;  
      /// Overall file metadata.  Filled in during the process and written during write_chunked_end()
      cudf::io::parquet::FileMetaData     md;  
      /// current write position for rowgroups/chunks
      std::size_t                         current_chunk_offset;
      /// optional user metadata
      table_metadata_with_nullability     user_metadata_with_nullability;  
      /// special parameter only used by detail::write() to indicate that we are guaranteeing 
      /// a single table write.  this enables some internal optimizations.
      table_metadata const*               user_metadata;
      /// only used in the write_chunked() case. copied from the (optionally) user supplied
      /// argument to write_parquet_chunked_begin()
      bool                                single_write_mode;

      pq_chunked_state(std::unique_ptr<writer> writer_ptr,
                       std::size_t curr_chunk_offset,
                       SetMetadata set_metadata,
                       table_metadata const* metadata,
                       table_metadata_with_nullability const* metadata_with_nullability,
                       SingleWriteMode mode = SingleWriteMode::NO,
                       cudaStream_t str = 0) :
         wp{std::move(writer_ptr)},
         current_chunk_offset{curr_chunk_offset},
         single_write_mode{mode == SingleWriteMode::YES},
         stream{str}
      {
         if (set_metadata == SetMetadata::WITH_NULLABILITY) {
            user_metadata_with_nullability = *metadata_with_nullability;
            user_metadata                  = &(this->user_metadata_with_nullability);
         } else {
            user_metadata = metadata;
         }
      }
   };

}  // namespace parquet
}  // namespace detail
}  // namespace io
}  // namespace experimental
}  // namespace cudf