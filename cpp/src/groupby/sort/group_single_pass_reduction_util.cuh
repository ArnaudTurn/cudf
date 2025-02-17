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

#pragma once

#include <reductions/arg_minmax_util.cuh>

#include <cudf/column/column.hpp>
#include <cudf/column/column_factories.hpp>
#include <cudf/column/column_view.hpp>
#include <cudf/detail/aggregation/aggregation.cuh>
#include <cudf/detail/iterator.cuh>
#include <cudf/detail/structs/utilities.hpp>
#include <cudf/detail/utilities/vector_factories.hpp>
#include <cudf/detail/valid_if.cuh>
#include <cudf/table/row_operators.cuh>
#include <cudf/types.hpp>
#include <cudf/utilities/span.hpp>

#include <rmm/cuda_stream_view.hpp>
#include <rmm/exec_policy.hpp>

#include <thrust/functional.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/iterator/discard_iterator.h>
#include <thrust/reduce.h>

namespace cudf {
namespace groupby {
namespace detail {

/**
 * @brief Binary operator with index values into the input column.
 *
 * @tparam T Type of the underlying column. Must support '<' operator.
 */
template <typename T>
struct element_arg_minmax_fn {
  column_device_view const d_col;
  bool const has_nulls;
  bool const arg_min;

  CUDA_DEVICE_CALLABLE auto operator()(size_type const& lhs_idx, size_type const& rhs_idx) const
  {
    // The extra bounds checking is due to issue github.com/rapidsai/cudf/9156 and
    // github.com/NVIDIA/thrust/issues/1525
    // where invalid random values may be passed here by thrust::reduce_by_key
    if (lhs_idx < 0 || lhs_idx >= d_col.size() || (has_nulls && d_col.is_null_nocheck(lhs_idx))) {
      return rhs_idx;
    }
    if (rhs_idx < 0 || rhs_idx >= d_col.size() || (has_nulls && d_col.is_null_nocheck(rhs_idx))) {
      return lhs_idx;
    }

    // Return `lhs_idx` iff:
    //   row(lhs_idx) <  row(rhs_idx) and finding ArgMin, or
    //   row(lhs_idx) >= row(rhs_idx) and finding ArgMax.
    auto const less = d_col.element<T>(lhs_idx) < d_col.element<T>(rhs_idx);
    return less == arg_min ? lhs_idx : rhs_idx;
  }
};

/**
 * @brief Value accessor for column which supports dictionary column too.
 *
 * @tparam T Type of the underlying column. For dictionary column, type of the key column.
 */
template <typename T>
struct value_accessor {
  column_device_view const col;
  bool const is_dict;
  value_accessor(column_device_view const& col) : col(col), is_dict(cudf::is_dictionary(col.type()))
  {
  }

  __device__ T value(size_type i) const
  {
    if (is_dict) {
      auto keys = col.child(dictionary_column_view::keys_column_index);
      return keys.element<T>(static_cast<size_type>(col.element<dictionary32>(i)));
    } else {
      return col.element<T>(i);
    }
  }
  __device__ auto operator()(size_type i) const { return value(i); }
};

/**
 * @brief Null replaced value accessor for column which supports dictionary column too.
 * For null value, returns null `init` value
 *
 * @tparam T Type of the underlying column. For dictionary column, type of the key column.
 */
template <typename T>
struct null_replaced_value_accessor : value_accessor<T> {
  using super_t = value_accessor<T>;
  bool const has_nulls;
  T const init;
  null_replaced_value_accessor(column_device_view const& col, T const& init, bool const has_nulls)
    : super_t(col), init(init), has_nulls(has_nulls)
  {
  }
  __device__ T operator()(size_type i) const
  {
    return has_nulls && super_t::col.is_null_nocheck(i) ? init : super_t::value(i);
  }
};

// Error case when no other overload or specialization is available
template <aggregation::Kind K, typename T, typename Enable = void>
struct group_reduction_functor {
  template <typename... Args>
  static std::unique_ptr<column> invoke(Args&&...)
  {
    CUDF_FAIL("Unsupported groupby reduction type-agg combination.");
  }
};

template <aggregation::Kind K>
struct group_reduction_dispatcher {
  template <typename T>
  std::unique_ptr<column> operator()(column_view const& values,
                                     size_type num_groups,
                                     cudf::device_span<cudf::size_type const> group_labels,
                                     rmm::cuda_stream_view stream,
                                     rmm::mr::device_memory_resource* mr)
  {
    return group_reduction_functor<K, T>::invoke(values, num_groups, group_labels, stream, mr);
  }
};

/**
 * @brief Check if the given aggregation K with data type T is supported in groupby reduction.
 */
template <aggregation::Kind K, typename T>
static constexpr bool is_group_reduction_supported()
{
  switch (K) {
    case aggregation::SUM:
      return cudf::is_numeric<T>() || cudf::is_duration<T>() || cudf::is_fixed_point<T>();
    case aggregation::PRODUCT: return cudf::detail::is_product_supported<T>();
    case aggregation::MIN:
    case aggregation::MAX: return cudf::is_fixed_width<T>() and is_relationally_comparable<T, T>();
    case aggregation::ARGMIN:
    case aggregation::ARGMAX:
      return is_relationally_comparable<T, T>() or std::is_same_v<T, cudf::struct_view>;
    default: return false;
  }
}

template <aggregation::Kind K, typename T>
struct group_reduction_functor<K, T, std::enable_if_t<is_group_reduction_supported<K, T>()>> {
  static std::unique_ptr<column> invoke(column_view const& values,
                                        size_type num_groups,
                                        cudf::device_span<cudf::size_type const> group_labels,
                                        rmm::cuda_stream_view stream,
                                        rmm::mr::device_memory_resource* mr)

  {
    using DeviceType  = device_storage_type_t<T>;
    using ResultType  = cudf::detail::target_type_t<T, K>;
    using ResultDType = device_storage_type_t<ResultType>;

    auto result_type = is_fixed_point<ResultType>()
                         ? data_type{type_to_id<ResultType>(), values.type().scale()}
                         : data_type{type_to_id<ResultType>()};

    std::unique_ptr<column> result =
      make_fixed_width_column(result_type, num_groups, mask_state::UNALLOCATED, stream, mr);

    if (values.is_empty()) { return result; }

    // Perform segmented reduction.
    auto const do_reduction = [&](auto const& inp_iter, auto const& out_iter, auto const& binop) {
      thrust::reduce_by_key(rmm::exec_policy(stream),
                            group_labels.data(),
                            group_labels.data() + group_labels.size(),
                            inp_iter,
                            thrust::make_discard_iterator(),
                            out_iter,
                            thrust::equal_to{},
                            binop);
    };

    auto const d_values_ptr = column_device_view::create(values, stream);
    auto const result_begin = result->mutable_view().template begin<ResultDType>();

    if constexpr (K == aggregation::ARGMAX || K == aggregation::ARGMIN) {
      auto const count_iter = thrust::make_counting_iterator<ResultType>(0);
      auto const binop =
        element_arg_minmax_fn<T>{*d_values_ptr, values.has_nulls(), K == aggregation::ARGMIN};
      do_reduction(count_iter, result_begin, binop);
    } else {
      using OpType    = cudf::detail::corresponding_operator_t<K>;
      auto init       = OpType::template identity<DeviceType>();
      auto inp_values = cudf::detail::make_counting_transform_iterator(
        0, null_replaced_value_accessor{*d_values_ptr, init, values.has_nulls()});
      do_reduction(inp_values, result_begin, OpType{});
    }

    if (values.has_nulls()) {
      rmm::device_uvector<bool> validity(num_groups, stream);
      do_reduction(cudf::detail::make_validity_iterator(*d_values_ptr),
                   validity.begin(),
                   thrust::logical_or{});

      auto [null_mask, null_count] =
        cudf::detail::valid_if(validity.begin(), validity.end(), thrust::identity{}, stream, mr);
      result->set_null_mask(std::move(null_mask), null_count);
    }
    return result;
  }
};

template <aggregation::Kind K>
struct group_reduction_functor<
  K,
  cudf::struct_view,
  std::enable_if_t<is_group_reduction_supported<K, cudf::struct_view>()>> {
  static std::unique_ptr<column> invoke(column_view const& values,
                                        size_type num_groups,
                                        cudf::device_span<cudf::size_type const> group_labels,
                                        rmm::cuda_stream_view stream,
                                        rmm::mr::device_memory_resource* mr)
  {
    // This is be expected to be size_type.
    using ResultType = cudf::detail::target_type_t<cudf::struct_view, K>;

    auto result = make_fixed_width_column(
      data_type{type_to_id<ResultType>()}, num_groups, mask_state::UNALLOCATED, stream, mr);

    if (values.is_empty()) { return result; }

    // When finding ARGMIN, we need to consider nulls as larger than non-null elements.
    // Thing is opposite for ARGMAX.
    auto const null_precedence =
      (K == aggregation::ARGMIN) ? null_order::AFTER : null_order::BEFORE;
    auto const flattened_values = structs::detail::flatten_nested_columns(
      table_view{{values}}, {}, std::vector<null_order>{null_precedence});
    auto const d_flattened_values_ptr = table_device_view::create(flattened_values, stream);
    auto const flattened_null_precedences =
      (K == aggregation::ARGMIN)
        ? cudf::detail::make_device_uvector_async(flattened_values.null_orders(), stream)
        : rmm::device_uvector<null_order>(0, stream);

    // Perform segmented reduction to find ARGMIN/ARGMAX.
    auto const do_reduction = [&](auto const& inp_iter, auto const& out_iter, auto const& binop) {
      thrust::reduce_by_key(rmm::exec_policy(stream),
                            group_labels.data(),
                            group_labels.data() + group_labels.size(),
                            inp_iter,
                            thrust::make_discard_iterator(),
                            out_iter,
                            thrust::equal_to{},
                            binop);
    };

    auto const count_iter   = thrust::make_counting_iterator<ResultType>(0);
    auto const result_begin = result->mutable_view().template begin<ResultType>();
    auto const binop        = cudf::reduction::detail::row_arg_minmax_fn(values.size(),
                                                                  *d_flattened_values_ptr,
                                                                  values.has_nulls(),
                                                                  flattened_null_precedences.data(),
                                                                  K == aggregation::ARGMIN);
    do_reduction(count_iter, result_begin, binop);

    if (values.has_nulls()) {
      // Generate bitmask for the output by segmented reduction of the input bitmask.
      auto const d_values_ptr = column_device_view::create(values, stream);
      auto validity           = rmm::device_uvector<bool>(num_groups, stream);
      do_reduction(cudf::detail::make_validity_iterator(*d_values_ptr),
                   validity.begin(),
                   thrust::logical_or{});

      auto [null_mask, null_count] =
        cudf::detail::valid_if(validity.begin(), validity.end(), thrust::identity{}, stream, mr);
      result->set_null_mask(std::move(null_mask), null_count);
    }

    return result;
  }
};

}  // namespace detail
}  // namespace groupby
}  // namespace cudf
