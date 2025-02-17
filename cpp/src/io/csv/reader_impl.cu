/*
 * Copyright (c) 2019-2021, NVIDIA CORPORATION.
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
 * @file reader_impl.cu
 * @brief cuDF-IO CSV reader class implementation
 */

#include "csv_common.h"
#include "csv_gpu.h"

#include <io/comp/io_uncomp.h>
#include <io/utilities/column_buffer.hpp>
#include <io/utilities/hostdevice_vector.hpp>
#include <io/utilities/parsing_utils.cuh>
#include <io/utilities/type_conversion.hpp>

#include <cudf/detail/utilities/cuda.cuh>
#include <cudf/detail/utilities/vector_factories.hpp>
#include <cudf/detail/utilities/visitor_overload.hpp>
#include <cudf/io/csv.hpp>
#include <cudf/io/datasource.hpp>
#include <cudf/io/detail/csv.hpp>
#include <cudf/io/types.hpp>
#include <cudf/strings/replace.hpp>
#include <cudf/table/table.hpp>
#include <cudf/utilities/error.hpp>
#include <cudf/utilities/span.hpp>

#include <rmm/cuda_stream_view.hpp>

#include <algorithm>
#include <iostream>
#include <memory>
#include <numeric>
#include <string>
#include <tuple>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

using std::string;
using std::vector;

using cudf::device_span;
using cudf::host_span;
using cudf::detail::make_device_uvector_async;

namespace cudf {
namespace io {
namespace detail {
namespace csv {
using namespace cudf::io::csv;
using namespace cudf::io;

namespace {

/**
 * @brief Offsets of CSV rows in device memory, accessed through a shrinkable span.
 *
 * Row offsets are stored this way to avoid reallocation/copies when discarding front or back
 * elements.
 */
class selected_rows_offsets {
  rmm::device_uvector<uint64_t> all;
  device_span<uint64_t const> selected;

 public:
  selected_rows_offsets(rmm::device_uvector<uint64_t>&& data,
                        device_span<uint64_t const> selected_span)
    : all{std::move(data)}, selected{selected_span}
  {
  }
  selected_rows_offsets(rmm::cuda_stream_view stream) : all{0, stream}, selected{all} {}

  operator device_span<uint64_t const>() const { return selected; }
  void shrink(size_t size)
  {
    CUDF_EXPECTS(size <= selected.size(), "New size must be smaller");
    selected = selected.subspan(0, size);
  }
  void erase_first_n(size_t n)
  {
    CUDF_EXPECTS(n <= selected.size(), "Too many elements to remove");
    selected = selected.subspan(n, selected.size() - n);
  }
  auto size() const { return selected.size(); }
  auto data() const { return selected.data(); }
};

/**
 * @brief Removes the first and Last quote in the string
 */
string removeQuotes(string str, char quotechar)
{
  // Exclude first and last quotation char
  const size_t first_quote = str.find(quotechar);
  if (first_quote != string::npos) { str.erase(first_quote, 1); }
  const size_t last_quote = str.rfind(quotechar);
  if (last_quote != string::npos) { str.erase(last_quote, 1); }

  return str;
}

/**
 * @brief Parse the first row to set the column names in the raw_csv parameter.
 * The first row can be either the header row, or the first data row
 */
std::vector<std::string> get_column_names(std::vector<char> const& header,
                                          parse_options_view const& parse_opts,
                                          int header_row,
                                          std::string prefix)
{
  std::vector<std::string> col_names;

  // If there is only a single character then it would be the terminator
  if (header.size() <= 1) { return col_names; }

  std::vector<char> first_row = header;
  int num_cols                = 0;

  bool quotation = false;
  for (size_t pos = 0, prev = 0; pos < first_row.size(); ++pos) {
    // Flip the quotation flag if current character is a quotechar
    if (first_row[pos] == parse_opts.quotechar) {
      quotation = !quotation;
    }
    // Check if end of a column/row
    else if (pos == first_row.size() - 1 ||
             (!quotation && first_row[pos] == parse_opts.terminator) ||
             (!quotation && first_row[pos] == parse_opts.delimiter)) {
      // This is the header, add the column name
      if (header_row >= 0) {
        // Include the current character, in case the line is not terminated
        int col_name_len = pos - prev + 1;
        // Exclude the delimiter/terminator is present
        if (first_row[pos] == parse_opts.delimiter || first_row[pos] == parse_opts.terminator) {
          --col_name_len;
        }
        // Also exclude '\r' character at the end of the column name if it's
        // part of the terminator
        if (col_name_len > 0 && parse_opts.terminator == '\n' && first_row[pos] == '\n' &&
            first_row[pos - 1] == '\r') {
          --col_name_len;
        }

        const string new_col_name(first_row.data() + prev, col_name_len);
        col_names.push_back(removeQuotes(new_col_name, parse_opts.quotechar));

        // Stop parsing when we hit the line terminator; relevant when there is
        // a blank line following the header. In this case, first_row includes
        // multiple line terminators at the end, as the new recStart belongs to
        // a line that comes after the blank line(s)
        if (!quotation && first_row[pos] == parse_opts.terminator) { break; }
      } else {
        // This is the first data row, add the automatically generated name
        col_names.push_back(prefix + std::to_string(num_cols));
      }
      num_cols++;

      // Skip adjacent delimiters if delim_whitespace is set
      while (parse_opts.multi_delimiter && pos < first_row.size() &&
             first_row[pos] == parse_opts.delimiter && first_row[pos + 1] == parse_opts.delimiter) {
        ++pos;
      }
      prev = pos + 1;
    }
  }

  return col_names;
}

template <typename C>
void erase_except_last(C& container, rmm::cuda_stream_view stream)
{
  cudf::detail::device_single_thread(
    [span = device_span<typename C::value_type>{container}] __device__() mutable {
      span.front() = span.back();
    },
    stream);
  container.resize(1, stream);
}

size_t find_first_row_start(char row_terminator, host_span<char const> data)
{
  // For now, look for the first terminator (assume the first terminator isn't within a quote)
  // TODO: Attempt to infer this from the data
  size_t pos = 0;
  while (pos < data.size() && data[pos] != row_terminator) {
    ++pos;
  }
  return std::min(pos + 1, data.size());
}

/**
 * @brief Finds row positions in the specified input data, and loads the selected data onto GPU.
 *
 * This function scans the input data to record the row offsets (relative to the start of the
 * input data). A row is actually the data/offset between two termination symbols.
 *
 * @param data Uncompressed input data in host memory
 * @param range_begin Only include rows starting after this position
 * @param range_end Only include rows starting before this position
 * @param skip_rows Number of rows to skip from the start
 * @param num_rows Number of rows to read; -1: all remaining data
 * @param load_whole_file Hint that the entire data will be needed on gpu
 * @param stream CUDA stream used for device memory operations and kernel launches
 * @return Input data and row offsets in the device memory
 */
std::pair<rmm::device_uvector<char>, selected_rows_offsets> load_data_and_gather_row_offsets(
  csv_reader_options const& reader_opts,
  parse_options const& parse_opts,
  std::vector<char>& header,
  host_span<char const> data,
  size_t range_begin,
  size_t range_end,
  size_t skip_rows,
  int64_t num_rows,
  bool load_whole_file,
  rmm::cuda_stream_view stream)
{
  constexpr size_t max_chunk_bytes = 64 * 1024 * 1024;  // 64MB
  size_t buffer_size               = std::min(max_chunk_bytes, data.size());
  size_t max_blocks =
    std::max<size_t>((buffer_size / cudf::io::csv::gpu::rowofs_block_bytes) + 1, 2);
  hostdevice_vector<uint64_t> row_ctx(max_blocks);
  size_t buffer_pos  = std::min(range_begin - std::min(range_begin, sizeof(char)), data.size());
  size_t pos         = std::min(range_begin, data.size());
  size_t header_rows = (reader_opts.get_header() >= 0) ? reader_opts.get_header() + 1 : 0;
  uint64_t ctx       = 0;

  // For compatibility with the previous parser, a row is considered in-range if the
  // previous row terminator is within the given range
  range_end += (range_end < data.size());

  // Reserve memory by allocating and then resetting the size
  rmm::device_uvector<char> d_data{
    (load_whole_file) ? data.size() : std::min(buffer_size * 2, data.size()), stream};
  d_data.resize(0, stream);
  rmm::device_uvector<uint64_t> all_row_offsets{0, stream};
  do {
    size_t target_pos = std::min(pos + max_chunk_bytes, data.size());
    size_t chunk_size = target_pos - pos;

    auto const previous_data_size = d_data.size();
    d_data.resize(target_pos - buffer_pos, stream);
    CUDA_TRY(cudaMemcpyAsync(d_data.begin() + previous_data_size,
                             data.begin() + buffer_pos + previous_data_size,
                             target_pos - buffer_pos - previous_data_size,
                             cudaMemcpyDefault,
                             stream.value()));

    // Pass 1: Count the potential number of rows in each character block for each
    // possible parser state at the beginning of the block.
    uint32_t num_blocks = cudf::io::csv::gpu::gather_row_offsets(parse_opts.view(),
                                                                 row_ctx.device_ptr(),
                                                                 device_span<uint64_t>(),
                                                                 d_data,
                                                                 chunk_size,
                                                                 pos,
                                                                 buffer_pos,
                                                                 data.size(),
                                                                 range_begin,
                                                                 range_end,
                                                                 skip_rows,
                                                                 stream);
    CUDA_TRY(cudaMemcpyAsync(row_ctx.host_ptr(),
                             row_ctx.device_ptr(),
                             num_blocks * sizeof(uint64_t),
                             cudaMemcpyDeviceToHost,
                             stream.value()));
    stream.synchronize();

    // Sum up the rows in each character block, selecting the row count that
    // corresponds to the current input context. Also stores the now known input
    // context per character block that will be needed by the second pass.
    for (uint32_t i = 0; i < num_blocks; i++) {
      uint64_t ctx_next = cudf::io::csv::gpu::select_row_context(ctx, row_ctx[i]);
      row_ctx[i]        = ctx;
      ctx               = ctx_next;
    }
    size_t total_rows = ctx >> 2;
    if (total_rows > skip_rows) {
      // At least one row in range in this batch
      all_row_offsets.resize(total_rows - skip_rows, stream);

      CUDA_TRY(cudaMemcpyAsync(row_ctx.device_ptr(),
                               row_ctx.host_ptr(),
                               num_blocks * sizeof(uint64_t),
                               cudaMemcpyHostToDevice,
                               stream.value()));

      // Pass 2: Output row offsets
      cudf::io::csv::gpu::gather_row_offsets(parse_opts.view(),
                                             row_ctx.device_ptr(),
                                             all_row_offsets,
                                             d_data,
                                             chunk_size,
                                             pos,
                                             buffer_pos,
                                             data.size(),
                                             range_begin,
                                             range_end,
                                             skip_rows,
                                             stream);
      // With byte range, we want to keep only one row out of the specified range
      if (range_end < data.size()) {
        CUDA_TRY(cudaMemcpyAsync(row_ctx.host_ptr(),
                                 row_ctx.device_ptr(),
                                 num_blocks * sizeof(uint64_t),
                                 cudaMemcpyDeviceToHost,
                                 stream.value()));
        stream.synchronize();

        size_t rows_out_of_range = 0;
        for (uint32_t i = 0; i < num_blocks; i++) {
          rows_out_of_range += row_ctx[i];
        }
        if (rows_out_of_range != 0) {
          // Keep one row out of range (used to infer length of previous row)
          auto new_row_offsets_size =
            all_row_offsets.size() - std::min(rows_out_of_range - 1, all_row_offsets.size());
          all_row_offsets.resize(new_row_offsets_size, stream);
          // Implies we reached the end of the range
          break;
        }
      }
      // num_rows does not include blank rows
      if (num_rows >= 0) {
        if (all_row_offsets.size() > header_rows + static_cast<size_t>(num_rows)) {
          size_t num_blanks = cudf::io::csv::gpu::count_blank_rows(
            parse_opts.view(), d_data, all_row_offsets, stream);
          if (all_row_offsets.size() - num_blanks > header_rows + static_cast<size_t>(num_rows)) {
            // Got the desired number of rows
            break;
          }
        }
      }
    } else {
      // Discard data (all rows below skip_rows), keeping one character for history
      size_t discard_bytes = std::max(d_data.size(), sizeof(char)) - sizeof(char);
      if (discard_bytes != 0) {
        erase_except_last(d_data, stream);
        buffer_pos += discard_bytes;
      }
    }
    pos = target_pos;
  } while (pos < data.size());

  auto const non_blank_row_offsets =
    io::csv::gpu::remove_blank_rows(parse_opts.view(), d_data, all_row_offsets, stream);
  auto row_offsets = selected_rows_offsets{std::move(all_row_offsets), non_blank_row_offsets};

  // Remove header rows and extract header
  const size_t header_row_index = std::max<size_t>(header_rows, 1) - 1;
  if (header_row_index + 1 < row_offsets.size()) {
    CUDA_TRY(cudaMemcpyAsync(row_ctx.host_ptr(),
                             row_offsets.data() + header_row_index,
                             2 * sizeof(uint64_t),
                             cudaMemcpyDeviceToHost,
                             stream.value()));
    stream.synchronize();

    const auto header_start = buffer_pos + row_ctx[0];
    const auto header_end   = buffer_pos + row_ctx[1];
    CUDF_EXPECTS(header_start <= header_end && header_end <= data.size(),
                 "Invalid csv header location");
    header.assign(data.begin() + header_start, data.begin() + header_end);
    if (header_rows > 0) { row_offsets.erase_first_n(header_rows); }
  }
  // Apply num_rows limit
  if (num_rows >= 0 && static_cast<size_t>(num_rows) < row_offsets.size() - 1) {
    row_offsets.shrink(num_rows + 1);
  }
  return {std::move(d_data), std::move(row_offsets)};
}

std::pair<rmm::device_uvector<char>, selected_rows_offsets> select_data_and_row_offsets(
  cudf::io::datasource* source,
  csv_reader_options const& reader_opts,
  std::vector<char>& header,
  parse_options const& parse_opts,
  rmm::cuda_stream_view stream)
{
  auto range_offset      = reader_opts.get_byte_range_offset();
  auto range_size        = reader_opts.get_byte_range_size();
  auto range_size_padded = reader_opts.get_byte_range_size_with_padding();
  auto skip_rows         = reader_opts.get_skiprows();
  auto skip_end_rows     = reader_opts.get_skipfooter();
  auto num_rows          = reader_opts.get_nrows();

  if (range_offset > 0 || range_size > 0) {
    CUDF_EXPECTS(reader_opts.get_compression() == compression_type::NONE,
                 "Reading compressed data using `byte range` is unsupported");
  }

  // Transfer source data to GPU
  if (!source->is_empty()) {
    auto data_size = (range_size_padded != 0) ? range_size_padded : source->size();
    auto buffer    = source->host_read(range_offset, data_size);

    auto h_data = host_span<char const>(  //
      reinterpret_cast<const char*>(buffer->data()),
      buffer->size());

    std::vector<char> h_uncomp_data_owner;

    if (reader_opts.get_compression() != compression_type::NONE) {
      h_uncomp_data_owner = get_uncompressed_data(h_data, reader_opts.get_compression());
      h_data              = h_uncomp_data_owner;
    }
    // None of the parameters for row selection is used, we are parsing the entire file
    const bool load_whole_file = range_offset == 0 && range_size == 0 && skip_rows <= 0 &&
                                 skip_end_rows <= 0 && num_rows == -1;

    // With byte range, find the start of the first data row
    size_t const data_start_offset =
      (range_offset != 0) ? find_first_row_start(parse_opts.terminator, h_data) : 0;

    // TODO: Allow parsing the header outside the mapped range
    CUDF_EXPECTS((range_offset == 0 || reader_opts.get_header() < 0),
                 "byte_range offset with header not supported");

    // Gather row offsets
    auto data_row_offsets =
      load_data_and_gather_row_offsets(reader_opts,
                                       parse_opts,
                                       header,
                                       h_data,
                                       data_start_offset,
                                       (range_size) ? range_size : h_data.size(),
                                       (skip_rows > 0) ? skip_rows : 0,
                                       num_rows,
                                       load_whole_file,
                                       stream);
    auto& row_offsets = data_row_offsets.second;
    // Exclude the rows that are to be skipped from the end
    if (skip_end_rows > 0 && static_cast<size_t>(skip_end_rows) < row_offsets.size()) {
      row_offsets.shrink(row_offsets.size() - skip_end_rows);
    }
    return data_row_offsets;
  }
  return {rmm::device_uvector<char>{0, stream}, selected_rows_offsets{stream}};
}

std::vector<data_type> select_data_types(std::vector<column_parse::flags> const& column_flags,
                                         std::vector<data_type> const& dtypes,
                                         int32_t num_actual_columns,
                                         int32_t num_active_columns)
{
  std::vector<data_type> selected_dtypes;

  if (dtypes.size() == 1) {
    // If it's a single dtype, assign that dtype to all active columns
    selected_dtypes.resize(num_active_columns, dtypes.front());
  } else {
    // If it's a list, assign dtypes to active columns in the given order
    CUDF_EXPECTS(static_cast<int>(dtypes.size()) >= num_actual_columns,
                 "Must specify data types for all columns");

    for (int i = 0; i < num_actual_columns; i++) {
      if (column_flags[i] & column_parse::enabled) { selected_dtypes.emplace_back(dtypes[i]); }
    }
  }
  return selected_dtypes;
}

std::vector<data_type> get_data_types_from_column_names(
  std::vector<column_parse::flags> const& column_flags,
  std::map<std::string, data_type> const& column_type_map,
  std::vector<std::string> const& column_names,
  int32_t num_actual_columns)
{
  std::vector<data_type> selected_dtypes;

  for (int32_t i = 0; i < num_actual_columns; i++) {
    if (column_flags[i] & column_parse::enabled) {
      auto const col_type_it = column_type_map.find(column_names[i]);
      CUDF_EXPECTS(col_type_it != column_type_map.end(),
                   "Must specify data types for all active columns");
      selected_dtypes.emplace_back(col_type_it->second);
    }
  }

  return selected_dtypes;
}

std::vector<data_type> infer_column_types(parse_options const& parse_opts,
                                          std::vector<column_parse::flags> const& column_flags,
                                          device_span<char const> data,
                                          device_span<uint64_t const> row_offsets,
                                          int32_t num_records,
                                          int32_t num_active_columns,
                                          data_type timestamp_type,
                                          rmm::cuda_stream_view stream)
{
  std::vector<data_type> dtypes;
  if (num_records == 0) {
    dtypes.resize(num_active_columns, data_type{type_id::EMPTY});
  } else {
    auto column_stats =
      cudf::io::csv::gpu::detect_column_types(parse_opts.view(),
                                              data,
                                              make_device_uvector_async(column_flags, stream),
                                              row_offsets,
                                              num_active_columns,
                                              stream);

    stream.synchronize();

    for (int col = 0; col < num_active_columns; col++) {
      unsigned long long int_count_total = column_stats[col].big_int_count +
                                           column_stats[col].negative_small_int_count +
                                           column_stats[col].positive_small_int_count;

      if (column_stats[col].null_count == num_records) {
        // Entire column is NULL; allocate the smallest amount of memory
        dtypes.emplace_back(cudf::type_id::INT8);
      } else if (column_stats[col].string_count > 0L) {
        dtypes.emplace_back(cudf::type_id::STRING);
      } else if (column_stats[col].datetime_count > 0L) {
        dtypes.emplace_back(cudf::type_id::TIMESTAMP_NANOSECONDS);
      } else if (column_stats[col].bool_count > 0L) {
        dtypes.emplace_back(cudf::type_id::BOOL8);
      } else if (column_stats[col].float_count > 0L ||
                 (column_stats[col].float_count == 0L && int_count_total > 0L &&
                  column_stats[col].null_count > 0L)) {
        // The second condition has been added to conform to
        // PANDAS which states that a column of integers with
        // a single NULL record need to be treated as floats.
        dtypes.emplace_back(cudf::type_id::FLOAT64);
      } else if (column_stats[col].big_int_count == 0) {
        dtypes.emplace_back(cudf::type_id::INT64);
      } else if (column_stats[col].big_int_count != 0 &&
                 column_stats[col].negative_small_int_count != 0) {
        dtypes.emplace_back(cudf::type_id::STRING);
      } else {
        // Integers are stored as 64-bit to conform to PANDAS
        dtypes.emplace_back(cudf::type_id::UINT64);
      }
    }
  }

  if (timestamp_type.id() != cudf::type_id::EMPTY) {
    for (auto& type : dtypes) {
      if (cudf::is_timestamp(type)) { type = timestamp_type; }
    }
  }

  for (size_t i = 0; i < dtypes.size(); i++) {
    // Replace EMPTY dtype with STRING
    if (dtypes[i].id() == type_id::EMPTY) { dtypes[i] = data_type{type_id::STRING}; }
  }

  return dtypes;
}

std::vector<column_buffer> decode_data(parse_options const& parse_opts,
                                       std::vector<column_parse::flags> const& column_flags,
                                       std::vector<std::string> const& column_names,
                                       device_span<char const> data,
                                       device_span<uint64_t const> row_offsets,
                                       host_span<data_type const> column_types,
                                       int32_t num_records,
                                       int32_t num_actual_columns,
                                       int32_t num_active_columns,
                                       rmm::cuda_stream_view stream,
                                       rmm::mr::device_memory_resource* mr)
{
  // Alloc output; columns' data memory is still expected for empty dataframe
  std::vector<column_buffer> out_buffers;
  out_buffers.reserve(column_types.size());

  for (int col = 0, active_col = 0; col < num_actual_columns; ++col) {
    if (column_flags[col] & column_parse::enabled) {
      const bool is_final_allocation = column_types[active_col].id() != type_id::STRING;
      auto out_buffer =
        column_buffer(column_types[active_col],
                      num_records,
                      true,
                      stream,
                      is_final_allocation ? mr : rmm::mr::get_current_device_resource());

      out_buffer.name         = column_names[col];
      out_buffer.null_count() = UNKNOWN_NULL_COUNT;
      out_buffers.emplace_back(std::move(out_buffer));
      active_col++;
    }
  }

  thrust::host_vector<void*> h_data(num_active_columns);
  thrust::host_vector<bitmask_type*> h_valid(num_active_columns);

  for (int i = 0; i < num_active_columns; ++i) {
    h_data[i]  = out_buffers[i].data();
    h_valid[i] = out_buffers[i].null_mask();
  }

  cudf::io::csv::gpu::decode_row_column_data(parse_opts.view(),
                                             data,
                                             make_device_uvector_async(column_flags, stream),
                                             row_offsets,
                                             make_device_uvector_async(column_types, stream),
                                             make_device_uvector_async(h_data, stream),
                                             make_device_uvector_async(h_valid, stream),
                                             stream);

  return out_buffers;
}

table_with_metadata read_csv(cudf::io::datasource* source,
                             csv_reader_options const& reader_opts,
                             parse_options const& parse_opts,
                             rmm::cuda_stream_view stream,
                             rmm::mr::device_memory_resource* mr)
{
  std::vector<char> header;

  auto const data_row_offsets =
    select_data_and_row_offsets(source, reader_opts, header, parse_opts, stream);

  auto const& data        = data_row_offsets.first;
  auto const& row_offsets = data_row_offsets.second;

  // Exclude the end-of-data row from number of rows with actual data
  auto num_records        = std::max(row_offsets.size(), 1ul) - 1;
  auto column_flags       = std::vector<column_parse::flags>();
  auto column_names       = std::vector<std::string>();
  auto num_actual_columns = static_cast<int32_t>(reader_opts.get_names().size());
  auto num_active_columns = num_actual_columns;

  // Check if the user gave us a list of column names
  if (not reader_opts.get_names().empty()) {
    column_flags.resize(reader_opts.get_names().size(), column_parse::enabled);
    column_names = reader_opts.get_names();
  } else {
    column_names = get_column_names(
      header, parse_opts.view(), reader_opts.get_header(), reader_opts.get_prefix());

    num_actual_columns = num_active_columns = column_names.size();

    column_flags.resize(num_actual_columns, column_parse::enabled);

    // Rename empty column names to "Unnamed: col_index"
    for (size_t col_idx = 0; col_idx < column_names.size(); ++col_idx) {
      if (column_names[col_idx].empty()) {
        column_names[col_idx] = string("Unnamed: ") + std::to_string(col_idx);
      }
    }

    // Looking for duplicates
    std::unordered_map<string, int> col_names_histogram;
    for (auto& col_name : column_names) {
      // Operator [] inserts a default-initialized value if the given key is not
      // present
      if (++col_names_histogram[col_name] > 1) {
        if (reader_opts.is_enabled_mangle_dupe_cols()) {
          // Rename duplicates of column X as X.1, X.2, ...; First appearance
          // stays as X
          do {
            col_name += "." + std::to_string(col_names_histogram[col_name] - 1);
          } while (col_names_histogram[col_name]++);
        } else {
          // All duplicate columns will be ignored; First appearance is parsed
          const auto idx    = &col_name - column_names.data();
          column_flags[idx] = column_parse::disabled;
        }
      }
    }

    // Update the number of columns to be processed, if some might have been
    // removed
    if (!reader_opts.is_enabled_mangle_dupe_cols()) {
      num_active_columns = col_names_histogram.size();
    }
  }

  // User can specify which columns should be parsed
  if (!reader_opts.get_use_cols_indexes().empty() || !reader_opts.get_use_cols_names().empty()) {
    std::fill(column_flags.begin(), column_flags.end(), column_parse::disabled);

    for (const auto index : reader_opts.get_use_cols_indexes()) {
      column_flags[index] = column_parse::enabled;
    }
    num_active_columns = std::unordered_set<int>(reader_opts.get_use_cols_indexes().begin(),
                                                 reader_opts.get_use_cols_indexes().end())
                           .size();

    for (const auto& name : reader_opts.get_use_cols_names()) {
      const auto it = std::find(column_names.begin(), column_names.end(), name);
      if (it != column_names.end()) {
        auto curr_it = it - column_names.begin();
        if (column_flags[curr_it] == column_parse::disabled) {
          column_flags[curr_it] = column_parse::enabled;
          num_active_columns++;
        }
      }
    }
  }

  // User can specify which columns should be read as datetime
  if (!reader_opts.get_parse_dates_indexes().empty() ||
      !reader_opts.get_parse_dates_names().empty()) {
    for (const auto index : reader_opts.get_parse_dates_indexes()) {
      column_flags[index] |= column_parse::as_datetime;
    }

    for (const auto& name : reader_opts.get_parse_dates_names()) {
      auto it = std::find(column_names.begin(), column_names.end(), name);
      if (it != column_names.end()) {
        column_flags[it - column_names.begin()] |= column_parse::as_datetime;
      }
    }
  }

  // User can specify which columns should be parsed as hexadecimal
  if (!reader_opts.get_parse_hex_indexes().empty() || !reader_opts.get_parse_hex_names().empty()) {
    for (const auto index : reader_opts.get_parse_hex_indexes()) {
      column_flags[index] |= column_parse::as_hexadecimal;
    }

    for (const auto& name : reader_opts.get_parse_hex_names()) {
      auto it = std::find(column_names.begin(), column_names.end(), name);
      if (it != column_names.end()) {
        column_flags[it - column_names.begin()] |= column_parse::as_hexadecimal;
      }
    }
  }

  // Return empty table rather than exception if nothing to load
  if (num_active_columns == 0) { return {std::make_unique<table>(), {}}; }

  auto metadata    = table_metadata{};
  auto out_columns = std::vector<std::unique_ptr<cudf::column>>();

  bool has_to_infer_column_types =
    std::visit([](const auto& dtypes) { return dtypes.empty(); }, reader_opts.get_dtypes());

  std::vector<data_type> column_types;
  if (has_to_infer_column_types) {
    column_types = infer_column_types(  //
      parse_opts,
      column_flags,
      data,
      row_offsets,
      num_records,
      num_active_columns,
      reader_opts.get_timestamp_type(),
      stream);
  } else {
    column_types =
      std::visit(cudf::detail::visitor_overload{
                   [&](const std::vector<data_type>& data_types) {
                     return select_data_types(
                       column_flags, data_types, num_actual_columns, num_active_columns);
                   },
                   [&](const std::map<std::string, data_type>& data_types) {
                     return get_data_types_from_column_names(  //
                       column_flags,
                       data_types,
                       column_names,
                       num_actual_columns);
                   }},
                 reader_opts.get_dtypes());
  }

  out_columns.reserve(column_types.size());

  if (num_records != 0) {
    auto out_buffers = decode_data(  //
      parse_opts,
      column_flags,
      column_names,
      data,
      row_offsets,
      column_types,
      num_records,
      num_actual_columns,
      num_active_columns,
      stream,
      mr);
    for (size_t i = 0; i < column_types.size(); ++i) {
      metadata.column_names.emplace_back(out_buffers[i].name);
      if (column_types[i].id() == type_id::STRING && parse_opts.quotechar != '\0' &&
          parse_opts.doublequote == true) {
        // PANDAS' default behavior of enabling doublequote for two consecutive
        // quotechars in quoted fields results in reduction to a single quotechar
        // TODO: Would be much more efficient to perform this operation in-place
        // during the conversion stage
        const std::string quotechar(1, parse_opts.quotechar);
        const std::string dblquotechar(2, parse_opts.quotechar);
        std::unique_ptr<column> col = cudf::make_strings_column(*out_buffers[i]._strings, stream);
        out_columns.emplace_back(
          cudf::strings::replace(col->view(), dblquotechar, quotechar, -1, mr));
      } else {
        out_columns.emplace_back(make_column(out_buffers[i], nullptr, stream, mr));
      }
    }
  } else {
    // Create empty columns
    for (size_t i = 0; i < column_types.size(); ++i) {
      out_columns.emplace_back(make_empty_column(column_types[i]));
    }
    // Handle empty metadata
    for (int col = 0; col < num_actual_columns; ++col) {
      if (column_flags[col] & column_parse::enabled) {
        metadata.column_names.emplace_back(column_names[col]);
      }
    }
  }
  return {std::make_unique<table>(std::move(out_columns)), std::move(metadata)};
}

/**
 * @brief Create a serialized trie for N/A value matching, based on the options.
 */
cudf::detail::trie create_na_trie(char quotechar,
                                  csv_reader_options const& reader_opts,
                                  rmm::cuda_stream_view stream)
{
  // Default values to recognize as null values
  static std::vector<std::string> const default_na_values{"",
                                                          "#N/A",
                                                          "#N/A N/A",
                                                          "#NA",
                                                          "-1.#IND",
                                                          "-1.#QNAN",
                                                          "-NaN",
                                                          "-nan",
                                                          "1.#IND",
                                                          "1.#QNAN",
                                                          "<NA>",
                                                          "N/A",
                                                          "NA",
                                                          "NULL",
                                                          "NaN",
                                                          "n/a",
                                                          "nan",
                                                          "null"};

  if (!reader_opts.is_enabled_na_filter()) { return cudf::detail::trie(0, stream); }

  std::vector<std::string> na_values = reader_opts.get_na_values();
  if (reader_opts.is_enabled_keep_default_na()) {
    na_values.insert(na_values.end(), default_na_values.begin(), default_na_values.end());
  }

  // Pandas treats empty strings as N/A if empty fields are treated as N/A
  if (std::find(na_values.begin(), na_values.end(), "") != na_values.end()) {
    na_values.push_back(std::string(2, quotechar));
  }

  return cudf::detail::create_serialized_trie(na_values, stream);
}

parse_options make_parse_options(csv_reader_options const& reader_opts,
                                 rmm::cuda_stream_view stream)
{
  auto parse_opts = parse_options{};

  if (reader_opts.is_enabled_delim_whitespace()) {
    parse_opts.delimiter       = ' ';
    parse_opts.multi_delimiter = true;
  } else {
    parse_opts.delimiter       = reader_opts.get_delimiter();
    parse_opts.multi_delimiter = false;
  }

  parse_opts.terminator = reader_opts.get_lineterminator();

  if (reader_opts.get_quotechar() != '\0' && reader_opts.get_quoting() != quote_style::NONE) {
    parse_opts.quotechar   = reader_opts.get_quotechar();
    parse_opts.keepquotes  = false;
    parse_opts.doublequote = reader_opts.is_enabled_doublequote();
  } else {
    parse_opts.quotechar   = '\0';
    parse_opts.keepquotes  = true;
    parse_opts.doublequote = false;
  }

  parse_opts.skipblanklines = reader_opts.is_enabled_skip_blank_lines();
  parse_opts.comment        = reader_opts.get_comment();
  parse_opts.dayfirst       = reader_opts.is_enabled_dayfirst();
  parse_opts.decimal        = reader_opts.get_decimal();
  parse_opts.thousands      = reader_opts.get_thousands();

  CUDF_EXPECTS(parse_opts.decimal != parse_opts.delimiter,
               "Decimal point cannot be the same as the delimiter");
  CUDF_EXPECTS(parse_opts.thousands != parse_opts.delimiter,
               "Thousands separator cannot be the same as the delimiter");

  // Handle user-defined true values, whereby field data is substituted with a
  // boolean true or numeric `1` value
  if (reader_opts.get_true_values().size() != 0) {
    parse_opts.trie_true =
      cudf::detail::create_serialized_trie(reader_opts.get_true_values(), stream);
  }

  // Handle user-defined false values, whereby field data is substituted with a
  // boolean false or numeric `0` value
  if (reader_opts.get_false_values().size() != 0) {
    parse_opts.trie_false =
      cudf::detail::create_serialized_trie(reader_opts.get_false_values(), stream);
  }

  // Handle user-defined N/A values, whereby field data is treated as null
  parse_opts.trie_na = create_na_trie(parse_opts.quotechar, reader_opts, stream);

  return parse_opts;
}

}  // namespace

table_with_metadata read_csv(std::unique_ptr<cudf::io::datasource>&& source,
                             csv_reader_options const& options,
                             rmm::cuda_stream_view stream,
                             rmm::mr::device_memory_resource* mr)
{
  auto parse_options = make_parse_options(options, stream);

  return read_csv(source.get(), options, parse_options, stream, mr);
}

}  // namespace csv
}  // namespace detail
}  // namespace io
}  // namespace cudf
